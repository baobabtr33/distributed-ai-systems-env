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

# --- helpers shared by the launch scripts ---------------------------------

# G and VT instances draw on a per-region vCPU quota rather than a GPU count.
# Spot and on-demand are metered separately.
gpu_quota_code() {
  if [[ "${SPOT}" == "true" ]]; then echo "L-3819A6DF"; else echo "L-DB2E81BA"; fi
}

# Check before launching. RunInstances would otherwise fail with
# VcpuLimitExceeded, which does not say which quota or how much is needed.
require_gpu_quota() {
  local code vcpus limit
  code="$(gpu_quota_code)"

  vcpus="$(aws ec2 describe-instance-types --instance-types "${INSTANCE_TYPE}" \
    --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus' --output text 2>/dev/null || echo "")"
  limit="$(aws service-quotas get-service-quota --service-code ec2 --quota-code "${code}" \
    --query 'Quota.Value' --output text 2>/dev/null || echo "")"

  # An unreadable quota is not the same as a quota of zero. Say so rather than
  # blocking a launch that might be fine.
  if [[ -z "${vcpus}" || -z "${limit}" ]]; then
    echo "WARNING: could not read instance vCPUs or the ${code} quota (permissions?)." >&2
    echo "         Launching anyway; RunInstances will report the real limit." >&2
    return 0
  fi

  echo "Quota ${code} in ${REGION}: ${limit} vCPUs, ${INSTANCE_TYPE} needs ${vcpus}"

  if awk "BEGIN{exit !(${limit} >= ${vcpus})}"; then
    return 0
  fi

  local pending
  pending="$(aws service-quotas list-requested-service-quota-change-history \
    --service-code ec2 --query "RequestedQuotas[?QuotaCode=='${code}'].[DesiredValue,Status]" \
    --output text 2>/dev/null | head -1)"

  cat >&2 <<MSG

ERROR: not enough quota to launch a ${INSTANCE_TYPE}.

  need   ${vcpus} vCPUs
  have   ${limit}
MSG
  if [[ -n "${pending}" ]]; then
    echo "  pending request: ${pending}" >&2
    echo "" >&2
    echo "A request is already in the queue. Nothing to do but wait; re-run when it is APPROVED." >&2
  else
    cat >&2 <<MSG

Request an increase (free, usually granted within minutes to a day):
  aws service-quotas request-service-quota-increase \\
    --service-code ec2 --quota-code ${code} --desired-value ${vcpus}
MSG
  fi
  echo "" >&2
  echo "Nothing was created, so there is nothing to clean up." >&2
  return 1
}
