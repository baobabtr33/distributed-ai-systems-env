# distributed-ai-systems-env

Terraform-provisioned GKE cluster with a scalable NVIDIA L4 GPU node pool and a Jupyter
environment, used to profile PyTorch DDP training and separate intra-node (PCIe) from
inter-node (network) NCCL collective cost.

**Status:** planning. Nothing provisioned yet.

See [docs/PLAN.md](docs/PLAN.md) for the full design, prerequisites, and build order.
