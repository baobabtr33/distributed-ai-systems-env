# The GPU node pool. node_count and gpus_per_node are the experiment: the same
# code produces 1x2 (intra-node, PCIe), 2x1 (inter-node, gVNIC) and 2x2 (both).

locals {
  # g2 is the only L4 family. vCPU count is fixed per GPU count, so the machine
  # type follows from gpus_per_node rather than being a separate variable.
  machine_type = {
    1 = "g2-standard-8"
    2 = "g2-standard-24"
    4 = "g2-standard-48"
  }[var.gpus_per_node]
}

resource "google_container_node_pool" "gpu" {
  name     = "gpu"
  cluster  = var.cluster_name
  location = var.zone

  # Defaults to 0 so an idle cluster costs only the control plane. Scaling is a
  # tfvars change, which is the point: the topology matrix is version-controlled.
  node_count = var.node_count

  node_config {
    machine_type = local.machine_type
    disk_size_gb = 200 # datasets, checkpoints and Chrome traces
    disk_type    = "pd-balanced"

    # Spot is 60-70% off and can be preempted with 30s notice. Checkpointing is
    # notebook 06's subject, so preemption is a feature of the rig, not a flaw.
    spot = var.spot

    guest_accelerator {
      type  = "nvidia-l4"
      count = var.gpus_per_node

      # Let GKE install the driver. The alternative is the NVIDIA installer
      # DaemonSet, which is an extra moving part with no benefit here.
      gpu_driver_installation_config {
        gpu_driver_version = "LATEST"
      }
    }

    # gVNIC is load-bearing for the inter-node numbers: without it the NIC tops
    # out well below line rate and every 2-node AllReduce figure is meaningless.
    gvnic {
      enabled = true
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = {
      role = "gpu"
    }

    # Keeps Jupyter and system pods off the expensive nodes. The torchrun Job
    # tolerates it explicitly; see jobs/torchrun-job.yaml.
    taint {
      key    = "nvidia.com/gpu"
      value  = "present"
      effect = "NO_SCHEDULE"
    }
  }

  # Placement matters for the inter-node measurement: COMPACT puts the nodes on
  # the same network fabric, so the number reflects the interconnect rather than
  # an arbitrary distance inside the zone.
  dynamic "placement_policy" {
    for_each = var.node_count > 1 ? [1] : []
    content {
      type = "COMPACT"
    }
  }

  management {
    auto_repair = true
    # Off: an upgrade mid-benchmark would swap the driver and CUDA version
    # underneath a run, which silently invalidates the comparison.
    auto_upgrade = false
  }

  lifecycle {
    # Changing GPU count or machine type replaces the pool; make the new one
    # first so the cluster is never left with no GPU capacity mid-change.
    create_before_destroy = true
  }
}
