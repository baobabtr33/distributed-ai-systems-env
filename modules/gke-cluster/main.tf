# A VPC-native GKE cluster with one small CPU node pool. The GPU pool is a
# separate module so it can scale to zero without touching the cluster.

resource "google_compute_network" "this" {
  name                    = "${var.name}-net"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "this" {
  name          = "${var.name}-subnet"
  network       = google_compute_network.this.id
  region        = var.region
  ip_cidr_range = "10.0.0.0/20"

  # Alias IP ranges: VPC-native is required for GKE and is what lets pods talk
  # across nodes without the routes-based fallback.
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.4.0.0/14"
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.8.0.0/20"
  }
}

# Cloud NAT so nodes without external IPs can still pull images and download
# CIFAR-10. Without this the private nodes below have no egress at all.
resource "google_compute_router" "this" {
  name    = "${var.name}-router"
  region  = var.region
  network = google_compute_network.this.id
}

resource "google_compute_router_nat" "this" {
  name                               = "${var.name}-nat"
  router                             = google_compute_router.this.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

resource "google_container_cluster" "this" {
  name     = var.name
  location = var.zone # zonal: one control plane, and GPU quota is per zone anyway

  # The default node pool is removed immediately; Terraform manages pools
  # explicitly so they can be replaced without recreating the cluster.
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = google_compute_network.this.id
  subnetwork = google_compute_subnetwork.this.id

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false # kubectl comes from outside the VPC
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.authorized_cidrs
      content {
        cidr_block   = cidr_blocks.value
        display_name = "authorized"
      }
    }
  }

  # Workload Identity is the supported way for a pod to act as a GCP service
  # account; the jupyter module's RBAC depends on this being on.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }

  # Jupyter's PVC is ReadWriteOnce and so cannot be shared with Job pods on
  # other nodes. Traces and checkpoints go to a GCS bucket mounted through this
  # driver instead, which is ReadWriteMany in effect and costs cents.
  addons_config {
    gcs_fuse_csi_driver_config {
      enabled = true
    }
  }

  # Deletion protection defaults to true in provider v5+, which makes
  # `terraform destroy` fail. This cluster is disposable by design.
  deletion_protection = false

  lifecycle {
    ignore_changes = [node_config] # set by the removed default pool
  }
}

resource "google_container_node_pool" "system" {
  name     = "system"
  cluster  = google_container_cluster.this.name
  location = var.zone

  node_count = 1

  node_config {
    machine_type = var.system_machine_type
    disk_size_gb = 50
    disk_type    = "pd-balanced"

    # Least privilege: the nodes need logging, monitoring and image pull, not
    # the default "cloud-platform" scope.
    oauth_scopes = [
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = { role = "system" }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}
