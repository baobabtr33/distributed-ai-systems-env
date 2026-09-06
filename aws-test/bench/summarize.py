#!/usr/bin/env python3
"""Compare a 1-GPU baseline against a multi-GPU run of ddp_allreduce.py.

Scaling efficiency is total throughput divided by (baseline throughput x world
size). Anything under 1.0 is the cost of the AllReduce plus the DDP overhead.
"""
import json
import sys


def load(path):
    with open(path) as fh:
        return json.load(fh)


def main(baseline_path, scaled_path):
    base, scaled = load(baseline_path), load(scaled_path)
    n = scaled["world_size"]

    print("device: %s" % scaled["device"])
    print()

    if scaled["allreduce"]:
        print("NCCL AllReduce, world_size=%d" % n)
        print("  %10s %12s %14s %14s" % ("size", "time", "algbw", "busbw"))
        for row in scaled["allreduce"]:
            print("  %8.1f MB %9.3f ms %11.2f GB/s %11.2f GB/s"
                  % (row["size_mb"], row["ms"], row["algbw_gbps"], row["busbw_gbps"]))
        peak = max(r["busbw_gbps"] for r in scaled["allreduce"])
        print("  peak busbw: %.2f GB/s" % peak)
        print()

    b, s = base["ddp"], scaled["ddp"]
    ideal = b["tokens_per_s_total"] * n
    eff = s["tokens_per_s_total"] / ideal

    print("DDP scaling, %d GPU -> %d GPU" % (base["world_size"], n))
    print("  %-22s %12s %12s" % ("", "1 GPU", "%d GPU" % n))
    print("  %-22s %12.2f %12.2f" % ("step time (ms)", b["step_ms"], s["step_ms"]))
    print("  %-22s %12.0f %12.0f" % ("tokens/s per GPU",
                                     b["tokens_per_s_per_gpu"], s["tokens_per_s_per_gpu"]))
    print("  %-22s %12.0f %12.0f" % ("tokens/s total",
                                     b["tokens_per_s_total"], s["tokens_per_s_total"]))
    print("  %-22s %12.2f %12.2f" % ("peak memory (GiB)",
                                     b["peak_mem_gib"], s["peak_mem_gib"]))
    print()
    print("  ideal %dx throughput : %.0f tokens/s" % (n, ideal))
    print("  measured            : %.0f tokens/s" % s["tokens_per_s_total"])
    print("  scaling efficiency  : %.1f%%" % (eff * 100))
    print("  communication cost  : %.1f%% of ideal" % ((1 - eff) * 100))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: summarize.py result_1gpu.json result_Ngpu.json")
    main(sys.argv[1], sys.argv[2])
