#!/usr/bin/env bash
# Opens a localhost-only tunnel to the Jupyter pod. No ingress, no public IP.
source "$(dirname "$0")/config.sh"

TOKEN_FILE="$(dirname "$0")/.jupyter-token"
if [[ ! -f "${TOKEN_FILE}" ]]; then
  echo "No ${TOKEN_FILE}. Run ./02-deploy-jupyter.sh first." >&2
  exit 1
fi
TOKEN="$(cat "${TOKEN_FILE}")"

echo
echo "Open this URL:"
echo "  http://127.0.0.1:${LOCAL_PORT}/lab?token=${TOKEN}"
echo
echo "Ctrl-C stops the tunnel (the pod keeps running)."
echo

kubectl -n "${NAMESPACE}" port-forward --address 127.0.0.1 \
  svc/jupyter "${LOCAL_PORT}:8888"
