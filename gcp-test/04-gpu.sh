#!/usr/bin/env bash
# Adds a single-GPU node pool to an existing cluster and moves Jupyter onto it.
#
# Kept separate from 01-create-cluster.sh so the GPU node can be added and removed
# without touching the cluster: node pools are the unit that costs money, and
# deleting one is much faster than recreating a cluster.
source "$(dirname "$0")/config.sh"

POOL="${POOL:-gpu-pool}"
POOL_MACHINE="${POOL_MACHINE:-g2-standard-8}"   # 1x L4, 8 vCPU, 32 GB
POOL_GPUS="${POOL_GPUS:-1}"

SPOT_FLAG=""
[[ "${SPOT}" == "true" ]] && SPOT_FLAG="--spot"

require_gpu_quota "${POOL_GPUS}"

if ensure_pool_usable "${POOL}"; then
  : # existing healthy pool, nothing to create
else
  echo "==> Creating node pool ${POOL}: ${POOL_MACHINE} with ${POOL_GPUS}x ${GPU_TYPE}"
  # min-nodes 0 lets the pool scale to zero later without deleting it.
  gcloud container node-pools create "${POOL}" \
    --cluster "${CLUSTER}" \
    --project "${PROJECT_ID}" \
    --zone "${ZONE}" \
    --machine-type "${POOL_MACHINE}" \
    --accelerator "type=${GPU_TYPE},count=${POOL_GPUS},gpu-driver-version=latest" \
    --num-nodes 1 \
    --enable-autoscaling --min-nodes 0 --max-nodes 1 \
    --disk-type "${DISK_TYPE}" \
    --disk-size "${DISK_SIZE}" \
    --enable-gvnic \
    --no-enable-autoupgrade \
    --no-enable-autorepair \
    ${SPOT_FLAG}
fi

echo "==> Waiting for a node to advertise ${POOL_GPUS} GPU(s) (driver install takes a few minutes)"
for i in $(seq 1 60); do
  ALLOC=$(kubectl get nodes -l cloud.google.com/gke-nodepool="${POOL}" \
    -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)
  if [[ -n "${ALLOC}" && "${ALLOC}" != "0" ]]; then
    echo "GPU allocatable on ${POOL}: ${ALLOC}"
    break
  fi
  echo "  [${i}/60] not ready yet..."
  sleep 10
done

if [[ -z "${ALLOC:-}" || "${ALLOC}" == "0" ]]; then
  echo "ERROR: no GPU became allocatable on ${POOL}." >&2
  kubectl get nodes -l cloud.google.com/gke-nodepool="${POOL}" >&2 || true
  exit 1
fi

echo "==> Redeploying Jupyter with ${POOL_GPUS} GPU(s)"
GPUS_PER_POD="${POOL_GPUS}" GPU_COUNT="${POOL_GPUS}" "$(dirname "$0")/02-deploy-jupyter.sh"

echo
echo "==> Verifying the GPU inside the pod"
kubectl -n "${NAMESPACE}" exec deploy/jupyter -- nvidia-smi
kubectl -n "${NAMESPACE}" exec deploy/jupyter -- python -c "
import torch
print('torch          :', torch.__version__)
print('cuda available :', torch.cuda.is_available())
print('device count   :', torch.cuda.device_count())
for i in range(torch.cuda.device_count()):
    p = torch.cuda.get_device_properties(i)
    print('  cuda:%d %s  %.1f GiB  sm_%d%d' % (i, p.name, p.total_memory/1024**3, p.major, p.minor))
"
echo
echo "Done. Open the notebook with:  ./03-port-forward.sh"
