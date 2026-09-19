output "name" {
  value = google_container_node_pool.gpu.name
}

output "machine_type" {
  value = local.machine_type
}

output "total_gpus" {
  value = var.node_count * var.gpus_per_node
}
