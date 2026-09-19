output "name" {
  value = google_container_cluster.this.name
}

output "endpoint" {
  value     = google_container_cluster.this.endpoint
  sensitive = true
}

output "ca_certificate" {
  value     = google_container_cluster.this.master_auth[0].cluster_ca_certificate
  sensitive = true
}

output "network" {
  value = google_compute_network.this.id
}

# Consumers must wait on the system pool, not just the cluster: scheduling a pod
# before it exists fails rather than pending.
output "system_node_pool" {
  value = google_container_node_pool.system.id
}
