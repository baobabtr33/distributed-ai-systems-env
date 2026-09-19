#!/usr/bin/env bash
# Creates the GCS bucket that holds Terraform state and enables the APIs the
# root module needs. Terraform cannot create its own backend, so this runs once
# by hand before the first `terraform init`.
#
#   PROJECT_ID=my-project ./bootstrap/bootstrap.sh
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?set PROJECT_ID}"
REGION="${REGION:-us-central1}"
BUCKET="${BUCKET:-${PROJECT_ID}-tfstate}"

echo "==> Project ${PROJECT_ID}, region ${REGION}, state bucket gs://${BUCKET}"

echo "==> Enabling APIs"
gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  cloudbilling.googleapis.com \
  billingbudgets.googleapis.com \
  --project "${PROJECT_ID}"

if gcloud storage buckets describe "gs://${BUCKET}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
  echo "==> Bucket gs://${BUCKET} already exists"
else
  echo "==> Creating gs://${BUCKET}"
  gcloud storage buckets create "gs://${BUCKET}" \
    --project "${PROJECT_ID}" \
    --location "${REGION}" \
    --uniform-bucket-level-access
fi

# Versioning is the recovery path for a corrupted or truncated state file.
gcloud storage buckets update "gs://${BUCKET}" --versioning --project "${PROJECT_ID}"

cat <<MSG

Done. Initialise Terraform against it:

  cd envs/dev
  cp terraform.tfvars.example terraform.tfvars   # then edit
  terraform init -backend-config=bucket=${BUCKET}

MSG
