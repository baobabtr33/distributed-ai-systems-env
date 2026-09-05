#!/usr/bin/env bash
# Deletes the cluster. This is the only reliable way to stop paying for the GPU.
source "$(dirname "$0")/config.sh"

echo "This deletes cluster '${CLUSTER}' in ${ZONE}, including the notebook PVC."
read -r -p "Type the cluster name to confirm: " CONFIRM
if [[ "${CONFIRM}" != "${CLUSTER}" ]]; then
  echo "Aborted."
  exit 1
fi

# Record the PVC's backing disk before the cluster goes away: deleting the
# cluster kills the CSI controller before it can reclaim the PersistentVolume,
# so the disk is orphaned and keeps billing. Nothing in the console links it
# back to the cluster afterwards.
ORPHANS="$(kubectl get pv -o jsonpath='{range .items[*]}{.spec.csi.volumeHandle}{"\n"}{end}' 2>/dev/null \
  | sed -n 's#.*/disks/##p' || true)"

gcloud container clusters delete "${CLUSTER}" \
  --zone "${ZONE}" --project "${PROJECT_ID}" --quiet

for disk in ${ORPHANS}; do
  if gcloud compute disks describe "${disk}" --zone "${ZONE}" \
       --project "${PROJECT_ID}" >/dev/null 2>&1; then
    echo "==> Deleting orphaned PVC disk ${disk}"
    gcloud compute disks delete "${disk}" --zone "${ZONE}" \
      --project "${PROJECT_ID}" --quiet
  fi
done

rm -f "$(dirname "$0")/.jupyter-token"

echo
echo "Deleted. Confirm nothing is left:"
echo "  gcloud compute instances list --project ${PROJECT_ID}"
echo "  gcloud compute disks list --project ${PROJECT_ID}"
