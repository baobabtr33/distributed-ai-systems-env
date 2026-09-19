variable "project_id" {
  type        = string
  description = "GCP project that owns the cluster."
}

variable "name" {
  type        = string
  description = "Cluster name; also the prefix for the network, subnet and NAT."
}

variable "region" {
  type        = string
  description = "Region for the subnet, router and NAT."
}

variable "zone" {
  type        = string
  description = "Zone for the cluster. Zonal rather than regional: GPU quota is per zone, and one control plane is enough for a benchmark rig."
}

variable "system_machine_type" {
  type        = string
  description = "Machine type for the CPU node pool that runs Jupyter and system pods."
  default     = "e2-standard-4"
}

variable "authorized_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach the public control plane endpoint. Narrow this to your own address."

  validation {
    # An empty list is not "allow everything": the block is still emitted, and a
    # master_authorized_networks_config with no cidr_blocks denies every
    # external address, which locks kubectl out of the cluster it just built.
    condition     = length(var.authorized_cidrs) > 0
    error_message = "authorized_cidrs must list at least one CIDR, or nothing outside the VPC can reach the control plane. Use \"$(curl -s https://checkip.amazonaws.com)/32\"."
  }
}
