#!/usr/bin/env bash
# Checks the things that most commonly block this sample: APIs and GPU quota.
source "$(dirname "$0")/config.sh"

echo "==> Enabling required APIs (idempotent)"
gcloud services enable container.googleapis.com compute.googleapis.com \
  --project "${PROJECT_ID}"

echo
echo "==> GPU quota in ${REGION}"
# Spot GPUs draw on PREEMPTIBLE_NVIDIA_L4_GPUS; on-demand draws on NVIDIA_L4_GPUS.
gcloud compute regions describe "${REGION}" --project "${PROJECT_ID}" --format=json \
  | python3 -c '
import json, sys
rows = [q for q in json.load(sys.stdin).get("quotas", []) if "L4" in q["metric"]]
if not rows:
    print("  no L4 quota entries found for this region")
for q in rows:
    print("  %-32s limit=%-8g usage=%g" % (q["metric"], q["limit"], q["usage"]))
'

echo
if [[ "${SPOT}" == "true" ]]; then
  echo "SPOT=true  -> you need PREEMPTIBLE_NVIDIA_L4_GPUS >= ${GPU_COUNT} in ${REGION}"
else
  echo "SPOT=false -> you need NVIDIA_L4_GPUS >= ${GPU_COUNT} in ${REGION}"
fi
echo "A limit of 0 means cluster creation will fail. Request quota at:"
echo "  https://console.cloud.google.com/iam-admin/quotas?project=${PROJECT_ID}"
echo
echo "Free-trial billing accounts cannot be granted GPU quota. Upgrade to a paid"
echo "account first; remaining trial credits carry over."
