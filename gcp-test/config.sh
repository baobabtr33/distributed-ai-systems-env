#!/usr/bin/env bash
# Shared configuration for gcp-test. Override any value by exporting it before
# running a script, e.g.  PROJECT_ID=my-project ./01-create-cluster.sh
set -euo pipefail

# Required. Falls back to whatever gcloud is currently configured with.
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"

# Zonal cluster: cheaper and simpler than regional for a single node.
ZONE="${ZONE:-us-central1-a}"
REGION="${REGION:-${ZONE%-*}}"

CLUSTER="${CLUSTER:-gpu-sample}"

# g2-standard-8 = 1x NVIDIA L4, 8 vCPU, 32 GB RAM.
MACHINE_TYPE="${MACHINE_TYPE:-g2-standard-8}"
GPU_TYPE="${GPU_TYPE:-nvidia-l4}"
# GPU_COUNT=0 builds the same cluster with no accelerator. Useful for validating
# the scripts, manifests and tunnel while GPU quota is still pending.
GPU_COUNT="${GPU_COUNT:-1}"

# Spot is ~60-70% cheaper but the node can be reclaimed at any time.
# Set SPOT=false for an on-demand node.
SPOT="${SPOT:-true}"

DISK_SIZE="${DISK_SIZE:-100}"
DISK_TYPE="${DISK_TYPE:-pd-balanced}"

NAMESPACE="${NAMESPACE:-jupyter}"
LOCAL_PORT="${LOCAL_PORT:-8888}"

if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" ]]; then
  echo "ERROR: PROJECT_ID is not set and gcloud has no default project." >&2
  echo "       Run: gcloud config set project YOUR_PROJECT_ID" >&2
  exit 1
fi

echo "project=${PROJECT_ID} zone=${ZONE} cluster=${CLUSTER} machine=${MACHINE_TYPE} gpu=${GPU_TYPE}x${GPU_COUNT} spot=${SPOT}"

# --- helpers shared by the GPU scripts ------------------------------------

# Metric names follow the accelerator name: nvidia-l4 -> NVIDIA_L4_GPUS.
gpu_quota_metric() {
  local base
  base="$(echo "${GPU_TYPE}" | tr 'a-z-' 'A-Z_')_GPUS"
  if [[ "${SPOT}" == "true" ]]; then echo "PREEMPTIBLE_${base}"; else echo "${base}"; fi
}

# Node pool creation with insufficient quota churns for two minutes, fails, and
# leaves the pool behind in ERROR state. Check first and say so plainly.
require_gpu_quota() {
  local needed="$1" metric global_limit region_limit
  metric="$(gpu_quota_metric)"

  global_limit="$(gcloud compute project-info describe --project "${PROJECT_ID}" --format=json 2>/dev/null \
    | python3 -c 'import json,sys; print(next((q["limit"] for q in json.load(sys.stdin).get("quotas",[]) if q["metric"]=="GPUS_ALL_REGIONS"), 0))')"
  region_limit="$(gcloud compute regions describe "${REGION}" --project "${PROJECT_ID}" --format=json 2>/dev/null \
    | python3 -c "import json,sys; print(next((q['limit'] for q in json.load(sys.stdin).get('quotas',[]) if q['metric']=='${metric}'), 0))")"

  echo "GPU quota: GPUS_ALL_REGIONS=${global_limit} (global), ${metric}=${region_limit} (${REGION}), need ${needed}"

  local ok=true
  awk "BEGIN{exit !(${global_limit} >= ${needed})}" || ok=false
  awk "BEGIN{exit !(${region_limit} >= ${needed})}" || ok=false

  if [[ "${ok}" != "true" ]]; then
    cat >&2 <<MSG

ERROR: not enough GPU quota to create this node pool.

  need   ${needed}x ${GPU_TYPE}
  have   GPUS_ALL_REGIONS=${global_limit} globally, ${metric}=${region_limit} in ${REGION}

Both must be at least ${needed}. Request an increase at
  https://console.cloud.google.com/iam-admin/quotas?project=${PROJECT_ID}
and re-run. Nothing was created, so there is nothing to clean up.
MSG
    return 1
  fi
}

# A pool left in ERROR by a failed create must be deleted, not reused: it holds
# the name but will never produce a node.
ensure_pool_usable() {
  local pool="$1" status
  status="$(gcloud container node-pools describe "${pool}" --cluster "${CLUSTER}" \
    --zone "${ZONE}" --project "${PROJECT_ID}" --format="value(status)" 2>/dev/null || true)"

  case "${status}" in
    "")        return 1 ;;   # does not exist, caller creates it
    RUNNING)   echo "==> Node pool ${pool} already exists and is RUNNING"; return 0 ;;
    *)
      echo "==> Node pool ${pool} is in state ${status}, deleting it before retrying"
      gcloud container node-pools delete "${pool}" --cluster "${CLUSTER}" \
        --zone "${ZONE}" --project "${PROJECT_ID}" --quiet
      return 1 ;;
  esac
}
