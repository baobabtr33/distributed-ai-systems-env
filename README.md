# distributed-ai-systems-env

Terraform-provisioned GKE cluster with a scalable NVIDIA L4 GPU node pool and a Jupyter
environment, used to profile PyTorch DDP training and separate intra-node (PCIe) from
inter-node (network) NCCL collective cost.

**Status:** planning. Nothing provisioned yet.

See [docs/PLAN.md](docs/PLAN.md) for the full design, prerequisites, and build order.

[`gcp-test/`](gcp-test/README.md) is a working `gcloud` + `kubectl` scaffold ahead of the
Terraform build: one GKE node with one NVIDIA L4, running JupyterLab behind a
`kubectl port-forward` tunnel. `cd sample && make preflight up jupyter forward`.

[`aws-test/`](aws-test/README.md) is the AWS counterpart: one `g6.xlarge` EC2 instance —
the same NVIDIA L4 — running JupyterLab over an SSH tunnel, so the throughput numbers are
directly comparable. A bare instance rather than EKS, because the first question is
whether a GPU can be obtained on AWS at all.

[`book-examples/`](book-examples/README.md) is a vendored, read-only copy of the example
code from [*Distributed AI Systems*](https://github.com/PacktPublishing/Distributed-AI-Systems)
(Packt, MIT licensed), pinned at commit `fd369f9`. Chapters 3 (DDP), 4 (FSDP) and 10
(benchmarking) cover the same ground as the notebook curriculum in the plan. Nothing in it
is wired into `gcp-test/`.
