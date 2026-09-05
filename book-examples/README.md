# book-examples

Vendored copy of the example code from **Distributed AI Systems** (Packt).

| | |
|---|---|
| Upstream | https://github.com/PacktPublishing/Distributed-AI-Systems |
| Commit | `fd369f9dc1c1f3718d4bf02d23f3f8ec2af2ee07` (2026-08-18) |
| Retrieved | 2026-09-05 |
| License | MIT, Copyright (c) 2026 Packt — see `LICENSE` |

This is a read-only reference. Nothing here is wired into `sample/` or the
Terraform build described in `docs/PLAN.md`; it is checked in so the examples stay
pinned to a known commit rather than drifting with upstream.

The upstream repository's own README is preserved as `UPSTREAM-README.md`.

## Chapters

| Chapter | Topic |
|---|---|
| 1 | Introduction to modern distributed AI |
| 2 | GPU hardware, networking, and parallelism strategies |
| 3 | Distributed training with PyTorch DDP |
| 4 | Scaling with Fully Sharded Data Parallel (FSDP) |
| 5 | Beyond state sharding with DeepSpeed and Megatron |
| 6 | Distributed inference fundamentals and vLLM |
| 8 | Running distributed training with Slurm |
| 9 | Production LLM serving stack |
| 10 | Distributed benchmarking and performance optimization |
| 11 | The evolving landscape of distributed AI |

Chapter 7 has no directory upstream — the sequence skips from 6 to 8.

## Most relevant to this project

- **Chapter 3** — DDP, the same territory as `sample/bench/ddp_allreduce.py` and
  notebooks 01–03 in `docs/PLAN.md`
- **Chapter 4** — FSDP, planned as notebook 05
- **Chapter 10** — benchmarking and profiling methodology
- **Chapter 2** — interconnect and parallelism background; useful context for why
  L4 over PCIe behaves differently from NVLink hardware

## Updating

```bash
git clone --depth 1 https://github.com/PacktPublishing/Distributed-AI-Systems.git /tmp/dais
rm -rf book-examples/chapter* book-examples/LICENSE book-examples/UPSTREAM-README.md
cp -R /tmp/dais/chapter* /tmp/dais/LICENSE book-examples/
mv /tmp/dais/README.md book-examples/UPSTREAM-README.md
```

Then update the commit hash and date in the table above.
