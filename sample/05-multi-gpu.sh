#!/usr/bin/env bash
# Puts two L4s on one node, gives both to the Jupyter pod, and measures what the
# second GPU actually buys: NCCL AllReduce bandwidth over PCIe and DDP scaling
# against a single-GPU baseline taken on the same hardware.
#
# L4 has no NVLink, so intra-node traffic crosses PCIe. Do not read these numbers
# as if they came from an A100 or H100.
source "$(dirname "$0")/config.sh"

POOL="${POOL:-gpu-pool-multi}"
POOL_MACHINE="${POOL_MACHINE:-g2-standard-24}"  # 2x L4, 24 vCPU, 96 GB
POOL_GPUS="${POOL_GPUS:-2}"
RESULTS="${RESULTS:-$(dirname "$0")/results}"

SPOT_FLAG=""
[[ "${SPOT}" == "true" ]] && SPOT_FLAG="--spot"

require_gpu_quota "${POOL_GPUS}"

if ensure_pool_usable "${POOL}"; then
  : # existing healthy pool, nothing to create
else
  echo "==> Creating node pool ${POOL}: ${POOL_MACHINE} with ${POOL_GPUS}x ${GPU_TYPE}"
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

echo "==> Waiting for a node to advertise ${POOL_GPUS} GPUs"
for i in $(seq 1 60); do
  ALLOC=$(kubectl get nodes -l cloud.google.com/gke-nodepool="${POOL}" \
    -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)
  if [[ "${ALLOC:-0}" -ge "${POOL_GPUS}" ]]; then
    echo "GPUs allocatable on ${POOL}: ${ALLOC}"
    break
  fi
  echo "  [${i}/60] allocatable=${ALLOC:-none}, want ${POOL_GPUS}..."
  sleep 10
done

if [[ "${ALLOC:-0}" -lt "${POOL_GPUS}" ]]; then
  echo "ERROR: ${POOL} never advertised ${POOL_GPUS} GPUs." >&2
  exit 1
fi

echo "==> Redeploying Jupyter with ${POOL_GPUS} GPUs"
GPUS_PER_POD="${POOL_GPUS}" GPU_COUNT="${POOL_GPUS}" MEMORY_LIMIT="${MEMORY_LIMIT:-48Gi}" \
  "$(dirname "$0")/02-deploy-jupyter.sh"

echo
echo "==> GPU topology as the pod sees it"
kubectl -n "${NAMESPACE}" exec deploy/jupyter -- nvidia-smi topo -m

echo
echo "==> Copying the benchmark into the pod"
POD="$(kubectl -n "${NAMESPACE}" get pod -l app=jupyter -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "${NAMESPACE}" cp "$(dirname "$0")/bench/ddp_allreduce.py" \
  "${POD}:/home/jovyan/work/ddp_allreduce.py"

mkdir -p "${RESULTS}"

# Both runs happen on the same node and the same pod, so the only variable is the
# number of ranks. That is what makes the comparison worth anything.
# torchrun's default rendezvous port is 29500, and a running Jupyter kernel can
# hold that port: ipykernel picks ephemeral ports and sometimes lands on it,
# which fails the run with EADDRINUSE. Rendezvous on port 0 so torchrun picks a
# free port instead. It also lets the two runs below happen back to back without
# waiting for a socket to leave TIME_WAIT.
RDZV="--rdzv-backend=c10d --rdzv-endpoint=127.0.0.1:0"

echo
echo "==> Baseline: 1 GPU"
kubectl -n "${NAMESPACE}" exec deploy/jupyter -- bash -lc "
  cd /home/jovyan/work && \
  NCCL_DEBUG=WARN torchrun ${RDZV} --nproc_per_node=1 ddp_allreduce.py \
    --tag 1gpu --json-out /home/jovyan/work/result_1gpu.json"

echo
echo "==> Scaled: ${POOL_GPUS} GPUs"
kubectl -n "${NAMESPACE}" exec deploy/jupyter -- bash -lc "
  cd /home/jovyan/work && \
  NCCL_DEBUG=WARN NCCL_IB_DISABLE=1 torchrun ${RDZV} --nproc_per_node=${POOL_GPUS} ddp_allreduce.py \
    --tag ${POOL_GPUS}gpu --json-out /home/jovyan/work/result_${POOL_GPUS}gpu.json"

for f in result_1gpu.json "result_${POOL_GPUS}gpu.json"; do
  kubectl -n "${NAMESPACE}" cp "${POD}:/home/jovyan/work/${f}" "${RESULTS}/${f}"
done

echo
echo "==> Scaling summary"
python3 "$(dirname "$0")/bench/summarize.py" \
  "${RESULTS}/result_1gpu.json" "${RESULTS}/result_${POOL_GPUS}gpu.json"
