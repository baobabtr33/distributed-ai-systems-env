#!/usr/bin/env bash
# Creates a zonal GKE cluster whose only node pool is a single GPU node.
# Everything (system pods + Jupyter) runs on that one node.
source "$(dirname "$0")/config.sh"

SPOT_FLAG=""
[[ "${SPOT}" == "true" ]] && SPOT_FLAG="--spot"

# GPU_COUNT=0 means a plain CPU node: no accelerator, no driver install.
ACCEL_FLAG=""
if [[ "${GPU_COUNT}" -gt 0 ]]; then
  ACCEL_FLAG="--accelerator=type=${GPU_TYPE},count=${GPU_COUNT},gpu-driver-version=latest"
fi

if gcloud container clusters describe "${CLUSTER}" --zone "${ZONE}" \
     --project "${PROJECT_ID}" >/dev/null 2>&1; then
  echo "Cluster ${CLUSTER} already exists in ${ZONE}. Nothing to do."
else
  echo "==> Creating cluster ${CLUSTER} (this takes ~5-8 minutes)"
  # gpu-driver-version=latest lets GKE install the NVIDIA driver for us, so no
  # driver DaemonSet is needed.
  gcloud container clusters create "${CLUSTER}" \
    --project "${PROJECT_ID}" \
    --zone "${ZONE}" \
    --release-channel regular \
    --num-nodes 1 \
    --machine-type "${MACHINE_TYPE}" \
    ${ACCEL_FLAG} \
    --disk-type "${DISK_TYPE}" \
    --disk-size "${DISK_SIZE}" \
    --enable-gvnic \
    --no-enable-autoupgrade \
    --no-enable-autorepair \
    ${SPOT_FLAG}
fi

echo "==> Fetching kubectl credentials"
gcloud container clusters get-credentials "${CLUSTER}" \
  --zone "${ZONE}" --project "${PROJECT_ID}"

if [[ "${GPU_COUNT}" -eq 0 ]]; then
  echo "==> GPU_COUNT=0, waiting for the node to become Ready"
  kubectl wait --for=condition=Ready node --all --timeout=10m
else
echo "==> Waiting for the GPU to be advertised by the node (driver install takes a few minutes)"
for i in $(seq 1 60); do
  ALLOC=$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)
  if [[ -n "${ALLOC}" && "${ALLOC}" != "0" ]]; then
    echo "GPU allocatable: ${ALLOC}"
    break
  fi
  echo "  [${i}/60] not ready yet..."
  sleep 10
done
fi

kubectl get nodes -o custom-columns=\
NAME:.metadata.name,STATUS:.status.conditions[-1].type,GPU:.status.allocatable.nvidia\\.com/gpu
