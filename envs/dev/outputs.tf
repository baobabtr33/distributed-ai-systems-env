output "cluster_name" {
  value = module.gke.name
}

output "zone" {
  value = var.zone
}

output "total_gpus" {
  value       = module.gpu.total_gpus
  description = "node_count * gpus_per_node. This is the world size a torchrun Job should use."
}

output "gpu_machine_type" {
  value = module.gpu.machine_type
}

output "namespace" {
  value = module.jupyter.namespace
}

output "jupyter_token" {
  value     = module.jupyter.token
  sensitive = true
}

output "port_forward" {
  value = "kubectl port-forward -n ${module.jupyter.namespace} svc/${module.jupyter.service} 8888:8888"
}

output "artifacts_bucket" {
  value = module.jupyter.artifacts_bucket
}
