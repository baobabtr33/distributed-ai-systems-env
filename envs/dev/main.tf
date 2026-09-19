provider "google" {
  project = var.project_id
  region  = var.region
}

data "google_client_config" "this" {}

data "google_project" "this" {
  project_id = var.project_id
}

# The Kubernetes provider is configured from the cluster this same apply
# creates. That works on a fresh apply, but changing the cluster and its
# workloads in one run can leave the provider pointed at a cluster that no
# longer exists — hence `make up` running the two targets in order.
provider "kubernetes" {
  host                   = "https://${module.gke.endpoint}"
  token                  = data.google_client_config.this.access_token
  cluster_ca_certificate = base64decode(module.gke.ca_certificate)
}

module "gke" {
  source = "../../modules/gke-cluster"

  project_id          = var.project_id
  name                = var.cluster_name
  region              = var.region
  zone                = var.zone
  system_machine_type = var.system_machine_type
  authorized_cidrs    = var.authorized_cidrs
}

module "gpu" {
  source = "../../modules/gpu-nodepool"

  cluster_name  = module.gke.name
  zone          = var.zone
  node_count    = var.node_count
  gpus_per_node = var.gpus_per_node
  spot          = var.spot
}

module "jupyter" {
  source = "../../modules/jupyter"

  project_id    = var.project_id
  region        = var.region
  namespace     = var.namespace
  notebooks_dir = abspath("${path.module}/../../notebooks")

  # Bucket names are globally unique, so default it off the project id.
  artifacts_bucket = coalesce(var.artifacts_bucket, "${var.project_id}-dai-artifacts")

  # Nothing schedules before the CPU pool exists.
  depends_on = [module.gke]
}

module "guardrails" {
  count  = var.billing_account == "" ? 0 : 1
  source = "../../modules/guardrails"

  name            = var.cluster_name
  billing_account = var.billing_account
  project_number  = data.google_project.this.number
  amount          = var.budget_amount
}
