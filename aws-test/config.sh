#!/usr/bin/env bash
# Shared configuration for aws-test. Override any value by exporting it before
# running a script, e.g.  INSTANCE_TYPE=g5.xlarge ./01-launch.sh
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-default}"
export AWS_PROFILE

REGION="${REGION:-us-east-1}"
export AWS_DEFAULT_REGION="${REGION}"

# g4dn.12xlarge = 4x NVIDIA T4 (16 GB each), 48 vCPU, 192 GB RAM. The cheapest
# way to get four GPUs on one node, which is what the DDP and AllReduce numbers
# in bench/ need. Note the T4 is sm_75: no bf16, so bench/ and the notebook fall
# back to fp16 (see pick_amp_dtype in bench/ddp_allreduce.py).
#
# Four GPUs, us-east-1 Spot at the time of writing:
#   g4dn.12xlarge  4x T4    64 GB total   $1.63/hr   no bf16
#   g6.12xlarge    4x L4    90 GB total   $1.85/hr   same GPU as ../gcp-test
#   g5.12xlarge    4x A10G  90 GB total   $1.98/hr
#   g6e.12xlarge   4x L40S 179 GB total   $6.35/hr
# One GPU, 4 vCPU of quota instead of 48:
#   g4dn.xlarge / g6.xlarge / g5.xlarge
#
# Smallest GPU footprint AWS sells, and so the smallest possible quota request:
#   g6f.large    2 vCPU, 8 GB RAM, a fractional L4 with 2861 MiB of VRAM,
#                $0.049/hr Spot in us-east-1d. Half the quota of a g4dn.xlarge.
#                Enough for the notebook's smoke test; bench/ needs smaller
#                dimensions than the defaults to fit in 2.8 GB.
INSTANCE_TYPE="${INSTANCE_TYPE:-g4dn.12xlarge}"

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

  # Only G and VT types draw on this bucket. A CPU type is metered against the
  # Standard quota, so checking the G/VT limit for one blocks a launch that
  # would have succeeded - which is exactly what happens when the scaffold is
  # run on a cheap CPU instance while the GPU quota case is still open.
  case "${INSTANCE_TYPE}" in
    g*|vt*) ;;
    *)
      echo "==> ${INSTANCE_TYPE} is not a G or VT type; skipping the GPU quota check"
      return 0
      ;;
  esac

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

# Spot prices for the same instance type differ by availability zone, and the
# spread is not small: at the time of writing g6.12xlarge was $1.85/hr in
# us-east-1f and $4.33/hr in us-east-1d. RunInstances without a subnet picks a
# zone for you, so pin it to the cheapest one that has a default subnet.
# Echoes an empty string if the price history or the subnet list is unreadable,
# which the caller treats as "let AWS choose".
cheapest_spot_subnet() {
  local az_prices az subnet
  az_prices="$(aws ec2 describe-spot-price-history \
    --instance-types "${INSTANCE_TYPE}" --product-descriptions "Linux/UNIX" \
    --start-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
    --query 'SpotPriceHistory[].[SpotPrice,AvailabilityZone]' \
    --output text 2>/dev/null | sort -g)" || return 0
  [[ -z "${az_prices}" ]] && return 0

  # Walk cheapest-first; the cheapest zone is no use without a subnet in it.
  while read -r price az; do
    [[ -z "${az}" ]] && continue
    subnet="$(aws ec2 describe-subnets \
      --filters "Name=availability-zone,Values=${az}" "Name=default-for-az,Values=true" \
      --query 'Subnets[0].SubnetId' --output text 2>/dev/null)"
    if [[ -n "${subnet}" && "${subnet}" != "None" ]]; then
      echo "${subnet} ${az} ${price}"
      return 0
    fi
  done <<<"${az_prices}"
}
