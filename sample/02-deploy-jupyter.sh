#!/usr/bin/env bash
# Deploys a single JupyterLab pod that owns the GPU.
source "$(dirname "$0")/config.sh"

TOKEN_FILE="$(dirname "$0")/.jupyter-token"

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Generate the access token once and reuse it across redeploys.
if [[ ! -f "${TOKEN_FILE}" ]]; then
  head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' > "${TOKEN_FILE}"
  chmod 600 "${TOKEN_FILE}"
fi
TOKEN="$(cat "${TOKEN_FILE}")"

kubectl -n "${NAMESPACE}" create secret generic jupyter-token \
  --from-literal=token="${TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

MANIFEST="$(dirname "$0")/k8s/jupyter.yaml"
# GPUS_PER_POD defaults to the node's GPU count: one node, one pod, all its GPUs.
GPUS_PER_POD="${GPUS_PER_POD:-${GPU_COUNT}}"
echo "==> Rendering the manifest for ${GPUS_PER_POD} GPU(s) per pod"
python3 "$(dirname "$0")/k8s/render.py" --gpus "${GPUS_PER_POD}" ${MEMORY_LIMIT:+--memory-limit "${MEMORY_LIMIT}"} \
  < "${MANIFEST}" | kubectl -n "${NAMESPACE}" apply -f -

echo "==> Waiting for the Jupyter pod (first pull of the CUDA image is several GB)"
kubectl -n "${NAMESPACE}" rollout status deploy/jupyter --timeout=20m


echo "==> Copying sample notebooks into the pod's persistent work directory"
POD="$(kubectl -n "${NAMESPACE}" get pod -l app=jupyter -o jsonpath='{.items[0].metadata.name}')"
for nb in "$(dirname "$0")"/notebooks/*.ipynb; do
  kubectl -n "${NAMESPACE}" cp "${nb}" "${POD}:/home/jovyan/work/$(basename "${nb}")"
done

echo
echo "Jupyter is running. Start the tunnel with:  ./03-port-forward.sh"
