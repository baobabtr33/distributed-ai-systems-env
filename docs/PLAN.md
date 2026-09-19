# Project Plan: distributed-ai-systems-env

**Goal:** A Terraform-provisioned GKE cluster with a scalable NVIDIA L4 GPU node pool and
a Jupyter environment, used to run GPT-2 DDP training benchmarks that isolate intra-node
(PCIe) from inter-node (network) NCCL collective cost.

**Portfolio emphasis:** ML systems performance. The deliverable is measured scaling data,
not a live service.

---

## Decisions

| Area | Choice | Rationale |
|---|---|---|
| Cloud | GCP | Best GPU ergonomics, per-second billing, easy Spot |
| Substrate | GKE, no Ray | Closer to raw Kubernetes skills; fewer moving parts |
| GPU | NVIDIA L4 Spot | Cheapest modern arch with bf16 + FlashAttention-2 support |
| Topology | 1–4 nodes, parameterized via tfvars | The node/GPU matrix *is* the experiment |
| Notebook access | Jupyter pod on GKE + `kubectl port-forward` | No ingress, no auth surface, no standby cost |
| Workload | GPT-2 124M on a small corpus | Communication-bound enough that AllReduce is visible in traces |
| State backend | GCS bucket + bootstrap script | Standard industry pattern |
| Audience | Anyone who clones the repo | `make up` / `make bench` / `make down` must work from scratch |
| Budget | Under $50 total | ~40 GPU-hours at 2 nodes |

Scope is deliberately limited to **training and profiling**. Inference serving (vLLM,
tensor-parallel) is explicitly out of scope for v1.

---

## Step 0 — Prerequisites (blocking)

These block every subsequent step. Do them before writing Terraform.

1. **Upgrade GCP billing from free trial to paid.** Trial accounts cannot be granted GPU
   quota. Remaining trial credits carry over and the upgrade itself does not consume them.
2. **Request GPU quota:** `PREEMPTIBLE_NVIDIA_L4_GPUS` >= 8 in `us-central1`. Approval
   takes hours to days.
3. **Enable APIs:** `container`, `compute`, `cloudbilling`, `billingbudgets`.

Verify Spot pricing at the time you run this — GCP adjusts it. As of planning,
`g2-standard-24` (2x L4, 24 vCPU) Spot is roughly $0.55–0.70/hr per node.

---

## Repository layout

```
bootstrap/          gcloud script: creates GCS state bucket, enables APIs
modules/
  gke-cluster/      cluster, VPC, subnet, CPU system node pool
  gpu-nodepool/     variable node_count (0-4), gpus_per_node (1|2|4),
                    Spot instances, gVNIC, autoscaling with min_node_count = 0
  jupyter/          notebook pod on CPU node, RBAC to submit Jobs, PVC for notebooks
  guardrails/       google_billing_budget with $25 / $40 alert thresholds
envs/dev/           tfvars and backend configuration
notebooks/          00 through 06 (see below)
jobs/               torchrun Kubernetes Job template
Makefile            bootstrap / up / scale / bench / down
```

---

## Topology matrix

`node_count` and `gpus_per_node` are Terraform variables, both defaulting to 0 so an idle
cluster costs only the control plane. The same code produces three measurement configs:

| Config | Path exercised |
|---|---|
| 1 node x 2 GPU | Intra-node only (PCIe peer-to-peer) |
| 2 nodes x 1 GPU | Inter-node only (gVNIC / TCP) |
| 2 nodes x 2 GPU | Both paths within one job |

Note that L4 has no NVLink, so intra-node transfers go over PCIe. The intra- vs inter-node
gap will be narrower than it would be on A100/H100 hardware. State this in the writeup
rather than letting a reader assume NVLink numbers.

---

## Notebook curriculum

| # | Content |
|---|---|
| 00 | Smoke test: `nvidia-smi`, `nvidia-smi topo -m`, NCCL init, verify node placement |
| 01 | Single-GPU GPT-2 124M baseline — tokens/sec, peak memory, step time |
| 02 | DDP on 1 node x 2 GPU — intra-node scaling efficiency vs the baseline |
| 03 | DDP on 2 nodes x 2 GPU — multi-node profiling, Chrome trace export |
| 04 | Gradient accumulation with `model.no_sync()` — measured AllReduce count reduction |
| 05 | FSDP vs DDP — memory versus throughput tradeoff |
| 06 | Spot preemption and checkpoint resume |

### Methodology caveat for notebook 03

`torch.profiler` reports the duration of `ncclDevKernel_AllReduce`, but it does **not**
label a kernel as inter-node or intra-node. That distinction is obtained by **differencing
configurations**: run 1x2 and 2x2 at identical global batch size and compare. This must be
stated explicitly in the README — it is the difference between a real measurement and a
hand-wave, and it is the first thing an interviewer will probe.

---

## Execution model

The Jupyter pod runs on a CPU node and holds no GPU. Notebooks submit an indexed
Kubernetes Job that runs `torchrun` across GPU pods. Rendezvous uses the `c10d` backend
over a headless Service. Access is via `kubectl port-forward`.

Required NCCL environment for g2 instances:

```
NCCL_DEBUG=INFO
NCCL_SOCKET_IFNAME=eth0
NCCL_IB_DISABLE=1      # no InfiniBand on g2
```

gVNIC must be enabled on the GPU node pool, otherwise inter-node bandwidth numbers are
meaningless.

---

## Cost guardrails

- GPU node pool autoscales to zero (`min_node_count = 0`). This, not Spot pricing alone, is
  what keeps the project inside $50.
- `google_billing_budget` resource with alerts at $25 and $40.
- Spot instances only, no on-demand fallback. Preemption mid-run is handled by the
  checkpoint/resume work in notebook 06.

---

## Resume bullets this project supports

> Built a Terraform-provisioned GKE GPU cluster (L4 Spot, scale-to-zero) parameterized
> across 1–4 nodes to isolate intra-node PCIe from inter-node NCCL collective cost in
> PyTorch DDP.

> Profiled GPT-2 training scaling with `torch.profiler`; quantified AllReduce overhead and
> reduced communication volume N× via gradient accumulation with `no_sync()`.

Replace N with the measured figure once notebook 04 has run.

---

## Build order

1. `bootstrap/` — state bucket and API enablement
2. `modules/gke-cluster` — cluster with CPU pool only, verify `kubectl` access
3. `modules/guardrails` — budget alerts, before any GPU spend
4. `modules/gpu-nodepool` — scale to 1 node, run notebook 00
5. `modules/jupyter` — notebook pod and Job submission RBAC
6. `jobs/` + notebooks 01–02 — single-GPU and intra-node results
7. Scale to 2 nodes, notebooks 03–04 — the core result
8. Notebooks 05–06, then the README writeup with charts
