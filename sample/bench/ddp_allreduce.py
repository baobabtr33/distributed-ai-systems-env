#!/usr/bin/env python3
"""NCCL AllReduce bandwidth and DDP scaling, for 1 to N GPUs on one node.

Run under torchrun so RANK / LOCAL_RANK / WORLD_SIZE are set:

    torchrun --nproc_per_node=2 ddp_allreduce.py
    torchrun --nproc_per_node=1 ddp_allreduce.py --tag baseline

At world size 1 the collective is a no-op, which is the point: it gives the
baseline that the multi-GPU numbers are compared against.

Bus bandwidth for a ring AllReduce is algorithmic bandwidth scaled by
2*(N-1)/N, which is the figure comparable across world sizes. See the NCCL
performance docs for the derivation.
"""
import argparse
import json
import os
import sys
import time

import torch
import torch.distributed as dist
import torch.nn as nn
from torch.nn.parallel import DistributedDataParallel


def log(rank, *a):
    if rank == 0:
        print(*a, flush=True)


def bench_allreduce(rank, world_size, device, sizes_mb, iters=20, warmup=5):
    rows = []
    for mb in sizes_mb:
        numel = int(mb * 1024**2 // 4)          # fp32
        buf = torch.ones(numel, device=device)

        for _ in range(warmup):
            dist.all_reduce(buf)
        torch.cuda.synchronize()

        dist.barrier()
        t0 = time.perf_counter()
        for _ in range(iters):
            dist.all_reduce(buf)
        torch.cuda.synchronize()
        elapsed = (time.perf_counter() - t0) / iters

        nbytes = numel * 4
        algbw = nbytes / elapsed / 1e9
        # Ring AllReduce moves 2*(N-1)/N times the buffer over the slowest link.
        busbw = algbw * (2 * (world_size - 1) / world_size) if world_size > 1 else 0.0
        rows.append({"size_mb": mb, "ms": elapsed * 1e3, "algbw_gbps": algbw,
                     "busbw_gbps": busbw})
        log(rank, "  %8.1f MB  %9.3f ms  algbw %7.2f GB/s  busbw %7.2f GB/s"
            % (mb, elapsed * 1e3, algbw, busbw))
    return rows


class Block(nn.Module):
    """A transformer-ish block, big enough that AllReduce is not free."""

    def __init__(self, d):
        super().__init__()
        self.norm = nn.LayerNorm(d)
        self.attn = nn.Linear(d, d)
        self.fc1 = nn.Linear(d, 4 * d)
        self.fc2 = nn.Linear(4 * d, d)

    def forward(self, x):
        x = x + self.attn(self.norm(x))
        return x + self.fc2(torch.nn.functional.gelu(self.fc1(self.norm(x))))


def bench_ddp(rank, world_size, device, d=1024, layers=8, batch=16, seq=512,
              iters=20, warmup=5):
    torch.manual_seed(0)
    model = nn.Sequential(*[Block(d) for _ in range(layers)]).to(device)
    if world_size > 1:
        model = DistributedDataParallel(model, device_ids=[device.index])

    params = sum(p.numel() for p in model.parameters())
    opt = torch.optim.AdamW(model.parameters(), lr=1e-4)
    x = torch.randn(batch, seq, d, device=device)

    def step():
        opt.zero_grad(set_to_none=True)
        with torch.autocast("cuda", dtype=torch.bfloat16):
            loss = model(x).square().mean()
        loss.backward()
        opt.step()

    for _ in range(warmup):
        step()
    torch.cuda.synchronize()

    if world_size > 1:
        dist.barrier()
    t0 = time.perf_counter()
    for _ in range(iters):
        step()
    torch.cuda.synchronize()
    per_step = (time.perf_counter() - t0) / iters

    local_tokens = batch * seq
    return {"params_m": params / 1e6, "step_ms": per_step * 1e3,
            "tokens_per_s_per_gpu": local_tokens / per_step,
            "tokens_per_s_total": local_tokens * world_size / per_step,
            "peak_mem_gib": torch.cuda.max_memory_allocated(device) / 1024**3}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", default="")
    ap.add_argument("--json-out", default="")
    ap.add_argument("--sizes-mb", type=float, nargs="+",
                    default=[1, 4, 16, 64, 256])
    args = ap.parse_args()

    rank = int(os.environ.get("RANK", 0))
    local_rank = int(os.environ.get("LOCAL_RANK", 0))
    world_size = int(os.environ.get("WORLD_SIZE", 1))

    if not torch.cuda.is_available():
        sys.exit("no CUDA device visible to rank %d. On GKE this means the pod has "
                 "no nvidia.com/gpu resource, or the node's driver is still "
                 "installing." % rank)
    if local_rank >= torch.cuda.device_count():
        sys.exit("local_rank %d but only %d GPU(s) visible: --nproc_per_node exceeds "
                 "the pod's GPU allocation." % (local_rank, torch.cuda.device_count()))

    torch.cuda.set_device(local_rank)
    device = torch.device("cuda", local_rank)

    if world_size > 1:
        dist.init_process_group(backend="nccl")

    name = torch.cuda.get_device_name(local_rank)
    log(rank, "world_size=%d  device=%s  tag=%s" % (world_size, name, args.tag or "-"))

    if world_size > 1:
        log(rank, "\nNCCL AllReduce:")
        allreduce = bench_allreduce(rank, world_size, device, args.sizes_mb)
    else:
        log(rank, "\nNCCL AllReduce: skipped, world_size=1")
        allreduce = []

    log(rank, "\nDDP step:")
    ddp = bench_ddp(rank, world_size, device)
    log(rank, "  params        %.1f M" % ddp["params_m"])
    log(rank, "  step time     %.2f ms" % ddp["step_ms"])
    log(rank, "  tokens/s/gpu  %.0f" % ddp["tokens_per_s_per_gpu"])
    log(rank, "  tokens/s tot  %.0f" % ddp["tokens_per_s_total"])
    log(rank, "  peak memory   %.2f GiB" % ddp["peak_mem_gib"])

    if rank == 0 and args.json_out:
        with open(args.json_out, "w") as fh:
            json.dump({"tag": args.tag, "world_size": world_size, "device": name,
                       "allreduce": allreduce, "ddp": ddp}, fh, indent=2)
        log(rank, "\nwrote %s" % args.json_out)

    if world_size > 1:
        dist.destroy_process_group()


if __name__ == "__main__":
    main()
