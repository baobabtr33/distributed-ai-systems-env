output "namespace" {
  value = kubernetes_namespace.this.metadata[0].name
}

output "service" {
  value = kubernetes_service.jupyter.metadata[0].name
}

output "token" {
  value     = random_password.token.result
  sensitive = true
}

output "url" {
  value       = "http://localhost:8888/lab?token=<terraform output -raw jupyter_token>"
  description = "Reachable only after `kubectl port-forward`; see the Makefile's forward target."
}

output "artifacts_bucket" {
  value = google_storage_bucket.artifacts.name
}

output "service_account" {
  value       = kubernetes_service_account.jupyter.metadata[0].name
  description = "Job pods must run as this account to reach the artifacts bucket."
}
