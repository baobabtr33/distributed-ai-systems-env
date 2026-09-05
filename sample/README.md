# sample — single GPU node on GKE running JupyterLab

The smallest thing that proves the environment works: one zonal GKE cluster, one
`g2-standard-8` node with one NVIDIA L4, and a JupyterLab pod that owns that GPU.
Access is a `kubectl port-forward` tunnel — no ingress, no public IP, no load balancer.

This is a scaffold for the multi-node Terraform build described in
[`../docs/PLAN.md`](../docs/PLAN.md), not part of it. It is `gcloud` + `kubectl` on
purpose, so the moving parts are visible before Terraform hides them.

## Prerequisites

- `gcloud` and `kubectl` on your PATH (`gcloud components install kubectl`)
- A GCP project on a **paid** billing account — free-trial accounts cannot be granted
  GPU quota
- `PREEMPTIBLE_NVIDIA_L4_GPUS >= 1` in your region (or `NVIDIA_L4_GPUS` if `SPOT=false`).
  `make preflight` prints your current limit; quota approval takes hours to days.

## Run it

```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID

cd sample
make preflight     # enables APIs, prints GPU quota
make up            # creates the cluster + GPU node, ~5-8 min
make jupyter       # deploys the notebook pod, ~5 min on first image pull
make forward       # prints http://127.0.0.1:8888/lab?token=... and holds the tunnel
```

Open the printed URL and run `work/00_gpu_smoke_test.ipynb`.

When finished:

```bash
make down          # deletes the cluster; asks you to type its name
```

## Adding GPUs

`04` and `05` add a GPU **node pool** to the cluster from step 01 rather than rebuilding
it. The pool is the unit that costs money, so it can be dropped and re-added in a couple
of minutes without losing the cluster, the PVC, or your notebooks.

```bash
make gpu         # gpu-pool:       g2-standard-8,  1x L4   -> Jupyter gets 1 GPU
make multi-gpu   # gpu-pool-multi: g2-standard-24, 2x L4   -> Jupyter gets 2 GPUs, then benchmarks
make pools       # what exists now
make drop-pools  # delete the GPU pools, keep everything else
```

`05-multi-gpu.sh` runs `bench/ddp_allreduce.py` twice in the same pod on the same node,
at `--nproc_per_node=1` and then `=2`, so the only variable between the two runs is the
rank count. It reports NCCL AllReduce algbw/busbw per message size, and DDP throughput
scaling with the communication cost as a percentage of ideal. Results land in `results/`
as JSON; `bench/summarize.py` formats the comparison.

L4 has no NVLink, so the 2-GPU numbers cross PCIe. They are not comparable to A100 or
H100 figures and should not be presented as if they were.

Both scripts check GPU quota before touching anything and exit in about two seconds if it
is insufficient:

```
GPU quota: GPUS_ALL_REGIONS=0.0 (global), PREEMPTIBLE_NVIDIA_L4_GPUS=0.0 (us-central1), need 1

ERROR: not enough GPU quota to create this node pool.
```

Without that check, `gcloud` churns for two minutes, fails with `GCE_QUOTA_EXCEEDED`, and
leaves the node pool behind in `ERROR` state, where it holds the name but will never
produce a node. `ensure_pool_usable` in `config.sh` deletes such a pool before retrying.

## Configuration

Everything is an environment variable read by `config.sh`; export it before running any
script or `make` target.

| Variable | Default | Notes |
|---|---|---|
| `PROJECT_ID` | current gcloud project | |
| `ZONE` | `us-central1-a` | Must be a zone that stocks L4 |
| `CLUSTER` | `gpu-sample` | |
| `MACHINE_TYPE` | `g2-standard-8` | 1x L4, 8 vCPU, 32 GB |
| `GPU_TYPE` / `GPU_COUNT` | `nvidia-l4` / `1` | |
| `SPOT` | `true` | `false` gives an on-demand node that cannot be preempted |
| `LOCAL_PORT` | `8888` | Local side of the tunnel |

To get 2 GPUs on the one node instead: `MACHINE_TYPE=g2-standard-24 GPU_COUNT=2 make up`.
That is enough to exercise the intra-node PCIe path, though the Jupyter pod as shipped
claims only one GPU — raise `nvidia.com/gpu` in `k8s/jupyter.yaml` to use both.

## What gets created

```
sample/
  config.sh              shared vars, sourced by every script
  00-preflight.sh        enable APIs, print GPU quota
  01-create-cluster.sh   create the cluster, wait for the driver to advertise the GPU
  02-deploy-jupyter.sh   namespace, token Secret, manifests, copy notebooks in
  03-port-forward.sh     localhost-only tunnel, prints the tokenised URL
  99-teardown.sh         delete the cluster (confirmation required)
  04-gpu.sh              add a 1x L4 node pool, move Jupyter onto it, verify
  05-multi-gpu.sh        add a 2x L4 node, benchmark 1 GPU vs 2 GPU
  k8s/jupyter.yaml       PVC + Deployment + ClusterIP Service
  k8s/render.py          renders the manifest for N GPUs per pod (0 = CPU only)
  bench/ddp_allreduce.py NCCL AllReduce bandwidth + DDP scaling, any world size
  bench/summarize.py     formats the 1-GPU vs N-GPU comparison
  notebooks/             00_gpu_smoke_test.ipynb
  results/               benchmark JSON (created by 05)
```

The cluster has exactly one node pool, so GKE system pods and Jupyter share the GPU node.
That is fine at this size and keeps the cost to a single machine.

## Notes

- **Cost.** One `g2-standard-8` Spot node runs roughly $0.20–0.30/hr, plus about $0.10/hr
  for the zonal control plane, plus a few cents a day for the 20 GiB PVC. Verify current
  pricing yourself; GCP adjusts Spot rates. `make down` is the only reliable off switch —
  stopping the port-forward stops nothing.
- **Spot preemption.** The node can be reclaimed with 30 seconds' notice. The pod
  reschedules onto the replacement node and `/home/jovyan/work` survives on the PVC, but
  the kernel dies and in-memory state is lost. Set `SPOT=false` if that matters.
- **Driver install.** `gpu-driver-version=latest` makes GKE install the NVIDIA driver, so
  there is no driver DaemonSet to apply. The GPU takes a few minutes after the node is
  `Ready` to show up as allocatable; `01-create-cluster.sh` polls for it.
- **Auth.** The Jupyter token is generated on first deploy and stored in `.jupyter-token`
  (gitignored) and a Kubernetes Secret. The Service is ClusterIP, so the notebook is
  reachable only through the tunnel.
- **`/dev/shm`.** Mounted as a 4 GiB memory-backed emptyDir. The 64 MB container default
  makes multi-worker PyTorch DataLoaders fail in ways that are annoying to diagnose.
- **`enableServiceLinks: false`.** A Service named `jupyter` makes Kubernetes inject the
  legacy Docker-link variable `JUPYTER_PORT=tcp://<clusterIP>:8888`. Jupyter Server reads
  `JUPYTER_PORT` as its listen port and dies with
  `ValueError: invalid literal for int() with base 10: 'tcp://...'`. Disabling the legacy
  injection is the fix; renaming the Service also works but is easy to regress.
- **torchrun rendezvous port.** The default is 29500, and a running Jupyter kernel can
  hold it: ipykernel picks ephemeral ports and sometimes lands there, failing the run with
  `EADDRINUSE`. `05` passes `--rdzv-endpoint=127.0.0.1:0` so torchrun picks a free port,
  which also lets the two runs happen back to back without waiting out `TIME_WAIT`.
- **`progressDeadlineSeconds: 1200`.** The image is 5.3 GB and takes ~2.5 minutes to pull
  on a cold node. The Deployment default of 600s can fail the rollout while the pod is
  still fine, and `kubectl rollout status --timeout` does not override it.

## Validating without GPU quota

`GPU_COUNT=0` builds the same cluster with a plain CPU node and deploys a filtered,
GPU-free variant of the manifest (see `k8s/strip-gpu.py`). Everything except the GPU cells
of notebook 00 is exercised:

```bash
CLUSTER=cpu-validate MACHINE_TYPE=e2-standard-4 GPU_COUNT=0 make up jupyter forward
```
