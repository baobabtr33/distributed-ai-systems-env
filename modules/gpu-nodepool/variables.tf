variable "cluster_name" {
  type        = string
  description = "Name of the cluster to attach the pool to. Paired with zone, which is why the name suffices."
}

variable "zone" {
  type        = string
  description = "Zone of the cluster. Must be one with L4 capacity and quota."
}

variable "node_count" {
  type        = number
  description = "GPU nodes in the pool. 0 leaves the cluster idle at control-plane cost only."
  default     = 0

  validation {
    condition     = var.node_count >= 0 && var.node_count <= 4
    error_message = "node_count must be 0-4; above that the L4 quota request in docs/PLAN.md is not enough."
  }
}

variable "gpus_per_node" {
  type        = number
  description = "L4s per node. Determines the g2 machine type."
  default     = 2

  validation {
    condition     = contains([1, 2, 4], var.gpus_per_node)
    error_message = "gpus_per_node must be 1, 2 or 4: the g2 family has no other L4 shapes."
  }
}

variable "spot" {
  type        = bool
  description = "Spot instances. Cheap and preemptible; set false only if a long run must not be interrupted."
  default     = true
}
