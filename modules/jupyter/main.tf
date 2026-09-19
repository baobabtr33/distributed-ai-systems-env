# JupyterLab on the CPU pool, holding no GPU of its own. Notebooks submit
# torchrun Jobs onto the GPU pool; see jobs/torchrun-job.yaml.
#
# Mounting the chapter-3 material is two-stage on purpose. The .py and .ipynb
# ship as ConfigMaps, which are read-only when mounted — a user who edits a
# notebook in Jupyter would get "Permission denied" on save. So an init
# container copies them onto a PVC on first start, and Jupyter serves the PVC.
# Edits survive pod restarts; deleting the PVC reseeds from the ConfigMaps.

resource "kubernetes_namespace" "this" {
  metadata {
    name = var.namespace
  }
}

resource "random_password" "token" {
  length  = 32
  special = false # goes in a URL
}

resource "kubernetes_secret" "token" {
  metadata {
    name      = "jupyter-token"
    namespace = kubernetes_namespace.this.metadata[0].name
  }
  data = {
    token = random_password.token.result
  }
  type = "Opaque"
}

# Two ConfigMaps rather than one: a ConfigMap is capped at 1 MiB, and the
# notebooks are the half that grows when more chapters are added.
resource "kubernetes_config_map" "scripts" {
  metadata {
    name      = "chapter3-scripts"
    namespace = kubernetes_namespace.this.metadata[0].name
  }
  data = {
    for f in fileset(var.notebooks_dir, "*.py") :
    f => file("${var.notebooks_dir}/${f}")
  }
}

resource "kubernetes_config_map" "notebooks" {
  metadata {
    name      = "chapter3-notebooks"
    namespace = kubernetes_namespace.this.metadata[0].name
  }
  data = merge(
    {
      for f in fileset(var.notebooks_dir, "*.ipynb") :
      f => file("${var.notebooks_dir}/${f}")
    },
    {
      "requirements.txt" = file("${var.notebooks_dir}/requirements.txt")
    }
  )
}

resource "kubernetes_persistent_volume_claim" "work" {
  metadata {
    name      = "jupyter-work"
    namespace = kubernetes_namespace.this.metadata[0].name
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = var.work_volume_size
      }
    }
  }
  # The PVC binds only when a pod consumes it; without this Terraform blocks
  # forever on a Pending claim.
  wait_until_bound = false
}

# Job pods use this same account, so they inherit both the bucket access and
# nothing else.
resource "kubernetes_service_account" "jupyter" {
  metadata {
    name      = "jupyter"
    namespace = kubernetes_namespace.this.metadata[0].name
    annotations = {
      "iam.gke.io/gcp-service-account" = google_service_account.jupyter.email
    }
  }
}

# Namespace-scoped: Jupyter submits and watches training Jobs and reads their
# logs. It has no reason to touch anything cluster-wide.
resource "kubernetes_role" "job_submitter" {
  metadata {
    name      = "job-submitter"
    namespace = kubernetes_namespace.this.metadata[0].name
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["create", "get", "list", "watch", "delete"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log"]
    verbs      = ["get", "list", "watch"]
  }

  # torchrun rendezvous uses a headless Service across the worker pods.
  rule {
    api_groups = [""]
    resources  = ["services"]
    verbs      = ["create", "get", "list", "delete"]
  }
}

resource "kubernetes_role_binding" "job_submitter" {
  metadata {
    name      = "job-submitter"
    namespace = kubernetes_namespace.this.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.job_submitter.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.jupyter.metadata[0].name
    namespace = kubernetes_namespace.this.metadata[0].name
  }
}

resource "kubernetes_deployment" "jupyter" {
  metadata {
    name      = "jupyter"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = { app = "jupyter" }
  }

  spec {
    replicas = 1

    # ReadWriteOnce: two replicas could not mount the same PVC, and a rolling
    # update would deadlock on it.
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = { app = "jupyter" }
    }

    template {
      metadata {
        labels = { app = "jupyter" }
        annotations = {
          # Injects the sidecar that backs the CSI volume below. Without it the
          # pod starts and the mount is simply absent.
          "gke-gcsfuse/volumes" = "true"

          # Reseed content changes onto a fresh pod. The init container skips
          # files that already exist, so user edits are not overwritten.
          "checksum/content" = sha256(join("", [
            jsonencode(kubernetes_config_map.scripts.data),
            jsonencode(kubernetes_config_map.notebooks.data),
          ]))
        }
      }

      spec {
        service_account_name = kubernetes_service_account.jupyter.metadata[0].name

        # Stay on the CPU pool. The GPU nodes carry a NoSchedule taint, so this
        # is belt and braces, but it also keeps Jupyter off a preemptible node.
        node_selector = { role = "system" }

        security_context {
          # jovyan in the upstream image
          run_as_user = 1000
          fs_group    = 100
        }

        init_container {
          name    = "seed-content"
          image   = var.image
          command = ["/bin/bash", "-c"]
          args = [<<-EOT
            set -euo pipefail
            # -n: never clobber an edited notebook on restart.
            cp -n /seed/scripts/* /home/jovyan/work/ 2>/dev/null || true
            cp -n /seed/notebooks/* /home/jovyan/work/ 2>/dev/null || true
            ls -la /home/jovyan/work/
          EOT
          ]

          volume_mount {
            name       = "work"
            mount_path = "/home/jovyan/work"
          }
          volume_mount {
            name       = "seed-scripts"
            mount_path = "/seed/scripts"
          }
          volume_mount {
            name       = "seed-notebooks"
            mount_path = "/seed/notebooks"
          }
        }

        container {
          name  = "jupyter"
          image = var.image

          command = ["start-notebook.sh"]
          args = [
            "--ServerApp.ip=0.0.0.0",
            "--ServerApp.port=8888",
            # No ingress and no public endpoint: access is kubectl port-forward
            # only, so the origin is always localhost.
            "--ServerApp.allow_origin=http://localhost:8888",
            "--ServerApp.root_dir=/home/jovyan/work",
            "--ServerApp.token=$(JUPYTER_TOKEN)",
          ]

          env {
            name = "JUPYTER_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.token.metadata[0].name
                key  = "token"
              }
            }
          }

          port {
            name           = "http"
            container_port = 8888
          }

          resources {
            requests = {
              cpu    = "500m"
              memory = "2Gi"
            }
            limits = {
              cpu    = "2"
              memory = "6Gi"
            }
          }

          readiness_probe {
            http_get {
              path = "/api"
              port = 8888
            }
            initial_delay_seconds = 10
            period_seconds        = 5
          }

          volume_mount {
            name       = "work"
            mount_path = "/home/jovyan/work"
          }

          # Where the Job pods' traces and checkpoints appear.
          volume_mount {
            name       = "artifacts"
            mount_path = "/home/jovyan/work/artifacts"
          }
        }

        volume {
          name = "artifacts"
          csi {
            driver = "gcsfuse.csi.storage.gke.io"
            volume_attributes = {
              bucketName   = google_storage_bucket.artifacts.name
              mountOptions = "implicit-dirs,uid=1000,gid=100"
            }
          }
        }

        volume {
          name = "work"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.work.metadata[0].name
          }
        }

        volume {
          name = "seed-scripts"
          config_map {
            name = kubernetes_config_map.scripts.metadata[0].name
          }
        }

        volume {
          name = "seed-notebooks"
          config_map {
            name = kubernetes_config_map.notebooks.metadata[0].name
          }
        }
      }
    }
  }
}

# ClusterIP, never a LoadBalancer: nothing about this should be reachable from
# the internet. `kubectl port-forward svc/jupyter 8888:8888`.
resource "kubernetes_service" "jupyter" {
  metadata {
    name      = "jupyter"
    namespace = kubernetes_namespace.this.metadata[0].name
  }
  spec {
    type     = "ClusterIP"
    selector = { app = "jupyter" }
    port {
      name        = "http"
      port        = 8888
      target_port = 8888
    }
  }
}

# --- shared artifacts --------------------------------------------------------
# The PVC above is ReadWriteOnce: only the node running Jupyter can mount it, so
# a Job pod on a GPU node cannot write its Chrome trace there. This bucket is
# the shared half — mounted by Jupyter and by every Job pod through the GCS
# FUSE CSI driver, which the cluster module enables.
#
# FUSE is the wrong home for the notebooks themselves (Jupyter's atomic-rename
# checkpointing behaves badly on it), which is why the split exists at all:
# notebooks on the PVC, large write-once artifacts here.

resource "google_storage_bucket" "artifacts" {
  name     = var.artifacts_bucket
  project  = var.project_id
  location = var.region

  uniform_bucket_level_access = true
  force_destroy               = true # traces are reproducible; do not block destroy

  # Traces from a profiled multi-node run are hundreds of MB and are worth
  # nothing a month later.
  lifecycle_rule {
    condition {
      age = var.artifacts_retention_days
    }
    action {
      type = "Delete"
    }
  }
}

resource "google_service_account" "jupyter" {
  account_id   = "${var.namespace}-jupyter"
  display_name = "Jupyter and torchrun Jobs"
  project      = var.project_id
}

resource "google_storage_bucket_iam_member" "jupyter" {
  bucket = google_storage_bucket.artifacts.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.jupyter.email}"
}

# Workload Identity: lets the KSA below impersonate the GSA above without a key.
resource "google_service_account_iam_member" "workload_identity" {
  service_account_id = google_service_account.jupyter.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.namespace}/jupyter]"
}
