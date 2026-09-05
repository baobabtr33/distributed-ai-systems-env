#!/usr/bin/env bash
# Deletes the cluster. This is the only reliable way to stop paying for the GPU.
source "$(dirname "$0")/config.sh"

echo "This deletes cluster '${CLUSTER}' in ${ZONE}, including the notebook PVC."
read -r -p "Type the cluster name to confirm: " CONFIRM
if [[ "${CONFIRM}" != "${CLUSTER}" ]]; then
  echo "Aborted."
  exit 1
fi

gcloud container clusters delete "${CLUSTER}" \
  --zone "${ZONE}" --project "${PROJECT_ID}" --quiet

rm -f "$(dirname "$0")/.jupyter-token"
echo "Deleted."
