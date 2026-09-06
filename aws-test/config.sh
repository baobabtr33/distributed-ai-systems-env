#!/usr/bin/env bash
# Shared configuration for aws-test. Override any value by exporting it before
# running a script, e.g.  INSTANCE_TYPE=g5.xlarge ./01-launch.sh
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-default}"
export AWS_PROFILE

REGION="${REGION:-us-east-1}"
export AWS_DEFAULT_REGION="${REGION}"

# g6.xlarge = 1x NVIDIA L4 (24 GB), 4 vCPU, 16 GB RAM. Deliberately the same GPU
# as the GKE run in ../gcp-test, so the throughput numbers are comparable.
#   g5.xlarge  = 1x A10G (24 GB)  - faster, usually easier quota
#   g4dn.xlarge = 1x T4 (16 GB)   - cheapest, no bf16
INSTANCE_TYPE="${INSTANCE_TYPE:-g6.xlarge}"

# Spot is roughly a third of on-demand but can be reclaimed with 2 minutes' notice.
SPOT="${SPOT:-true}"

NAME="${NAME:-gpu-test}"
KEY_NAME="${KEY_NAME:-${NAME}-key}"
KEY_FILE="${KEY_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/${KEY_NAME}.pem}"
SG_NAME="${SG_NAME:-${NAME}-sg}"
VOLUME_SIZE="${VOLUME_SIZE:-100}"
LOCAL_PORT="${LOCAL_PORT:-8888}"

# Every resource this scaffold creates carries this tag, so teardown can find
# them without a hand-maintained list.
TAG_KEY="${TAG_KEY:-aws-test}"
TAG_VALUE="${TAG_VALUE:-${NAME}}"

STATE_DIR="${STATE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.state}"
mkdir -p "${STATE_DIR}"

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "ERROR: AWS credentials are not working for profile '${AWS_PROFILE}'." >&2
  echo "       Run: aws configure --profile ${AWS_PROFILE}" >&2
  exit 1
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

echo "account=${ACCOUNT_ID} region=${REGION} type=${INSTANCE_TYPE} spot=${SPOT} name=${NAME}"
