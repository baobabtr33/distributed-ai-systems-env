#!/usr/bin/env bash
# Checks the thing that most commonly blocks this: the G-instance vCPU quota.
#
# AWS does not meter GPUs directly. G and VT instances draw on a single vCPU
# quota per region, so a g6.xlarge needs 4 vCPUs of "Running On-Demand G and VT
# Instances" (quota L-DB2E81BA), or the Spot equivalent (L-3819A6DF). A new
# account is frequently at 0 and must request an increase, exactly like GCP.
source "$(dirname "$0")/config.sh"

if [[ "${SPOT}" == "true" ]]; then
  QUOTA_CODE="L-3819A6DF"; QUOTA_LABEL="All G and VT Spot Instance Requests"
else
  QUOTA_CODE="L-DB2E81BA"; QUOTA_LABEL="Running On-Demand G and VT instances"
fi

VCPUS="$(aws ec2 describe-instance-types --instance-types "${INSTANCE_TYPE}" \
  --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus' --output text 2>/dev/null || echo "?")"

echo
echo "==> ${INSTANCE_TYPE} needs ${VCPUS} vCPUs of ${QUOTA_LABEL}"
LIMIT="$(aws service-quotas get-service-quota --service-code ec2 --quota-code "${QUOTA_CODE}" \
  --query 'Quota.Value' --output text 2>/dev/null || echo "0")"
echo "    quota ${QUOTA_CODE} in ${REGION}: ${LIMIT}"

echo
echo "==> GPU instance types offered in ${REGION}"
aws ec2 describe-instance-type-offerings --location-type region \
  --filters "Name=instance-type,Values=g6.*,g5.*,g4dn.*" \
  --query 'InstanceTypeOfferings[].InstanceType' --output text 2>/dev/null \
  | tr '\t' '\n' | sort | head -12 | sed 's/^/    /'

echo
if awk "BEGIN{exit !(${LIMIT} >= ${VCPUS})}"; then
  echo "OK: quota is sufficient to launch one ${INSTANCE_TYPE}."
else
  cat <<MSG
ERROR: not enough quota to launch a ${INSTANCE_TYPE}.

  need   ${VCPUS} vCPUs
  have   ${LIMIT}

Request an increase (free, usually granted within minutes to a day):
  https://${REGION}.console.aws.amazon.com/servicequotas/home/services/ec2/quotas/${QUOTA_CODE}

Or from the CLI:
  aws service-quotas request-service-quota-increase \\
    --service-code ec2 --quota-code ${QUOTA_CODE} --desired-value ${VCPUS}
MSG
  exit 1
fi

echo
echo "==> Current Spot price for ${INSTANCE_TYPE}"
aws ec2 describe-spot-price-history --instance-types "${INSTANCE_TYPE}" \
  --product-descriptions "Linux/UNIX" --max-items 3 \
  --query 'SpotPriceHistory[].[AvailabilityZone,SpotPrice]' --output text 2>/dev/null \
  | sed 's/^/    /' || echo "    (unavailable)"
