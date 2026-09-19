variable "project_id" {
  type        = string
  description = "GCP project id."
}

variable "region" {
  type        = string
  description = "Region. us-central1 has the widest L4 availability."
  default     = "us-central1"
}

variable "zone" {
  type        = string
  description = "Zone for the cluster and the GPU pool. Must hold your L4 quota."
  default     = "us-central1-a"
}

variable "cluster_name" {
  type    = string
  default = "dai-env"
}

variable "system_machine_type" {
  type    = string
  default = "e2-standard-4"
}

variable "authorized_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach the control plane. Required: an empty list denies all external access. 0.0.0.0/0 exposes the API server to the internet."
}

variable "namespace" {
  type    = string
  default = "dai"
}

variable "artifacts_bucket" {
  type        = string
  description = "Bucket for traces and checkpoints, shared by Jupyter and the Job pods. Null derives it from project_id."
  default     = null
}

# --- the topology matrix -----------------------------------------------------
# 1 node  x 2 GPU  intra-node only (PCIe peer-to-peer)
# 2 nodes x 1 GPU  inter-node only (gVNIC / TCP)
# 2 nodes x 2 GPU  both paths in one job
variable "node_count" {
  type        = number
  description = "GPU nodes. 0 (default) means an idle cluster at control-plane cost only."
  default     = 0
}

variable "gpus_per_node" {
  type    = number
  default = 2
}

variable "spot" {
  type    = bool
  default = true
}

# --- guardrails --------------------------------------------------------------
variable "billing_account" {
  type        = string
  description = "Billing account id. Empty disables the budget module: the billing API needs permissions a plain project owner may not have."
  default     = ""
}

variable "budget_amount" {
  type    = number
  default = 50
}
