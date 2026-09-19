variable "namespace" {
  type        = string
  description = "Namespace for Jupyter and the training Jobs it submits."
  default     = "dai"
}

variable "notebooks_dir" {
  type        = string
  description = "Absolute path to the repository's notebooks/ directory. Its .py, .ipynb and requirements.txt are mounted into the pod."
}

variable "image" {
  type        = string
  description = "Jupyter image. Needs only a kernel and kubectl-free job submission via the Kubernetes API; the GPU work happens in the Job pods, not here."
  default     = "quay.io/jupyter/scipy-notebook:2024-10-28"
}

variable "work_volume_size" {
  type        = string
  description = "Size of the PVC holding notebooks, checkpoints and Chrome traces. Traces from a profiled multi-node run are large."
  default     = "50Gi"
}

variable "project_id" {
  type        = string
  description = "GCP project; the artifacts bucket and its service account live here."
}

variable "region" {
  type        = string
  description = "Location for the artifacts bucket. Same region as the cluster, or every trace read crosses regions."
}

variable "artifacts_bucket" {
  type        = string
  description = "Globally unique bucket name for traces and checkpoints, shared between Jupyter and the Job pods."
}

variable "artifacts_retention_days" {
  type        = number
  description = "Traces are large and reproducible; delete them after this many days."
  default     = 30
}
