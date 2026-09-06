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

# Run a command, and distinguish "it said no" from "I was not allowed to ask".
# Swallowing an AccessDenied into a default of 0 would report a quota problem
# that does not exist and send you to the wrong console page.
try_aws() {
  local label="$1"; shift
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [[ ${rc} -ne 0 ]]; then
    if grep -qiE "AccessDenied|UnauthorizedOperation|not authorized" <<<"${out}"; then
      echo "PERMISSION_DENIED"
    else
      echo "ERROR"
    fi
    return 1
  fi
  echo "${out}"
}

VCPUS="$(try_aws "ec2:DescribeInstanceTypes" \
  aws ec2 describe-instance-types --instance-types "${INSTANCE_TYPE}" \
  --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus' --output text)" || VCPUS="PERMISSION_DENIED"

echo
echo "==> ${INSTANCE_TYPE} vCPUs: ${VCPUS}  (drawn from: ${QUOTA_LABEL})"

LIMIT="$(try_aws "servicequotas:GetServiceQuota" \
  aws service-quotas get-service-quota --service-code ec2 --quota-code "${QUOTA_CODE}" \
  --query 'Quota.Value' --output text)" || LIMIT="PERMISSION_DENIED"
echo "    quota ${QUOTA_CODE} in ${REGION}: ${LIMIT}"

if [[ "${VCPUS}" == "PERMISSION_DENIED" || "${LIMIT}" == "PERMISSION_DENIED" ]]; then
  cat >&2 <<MSG

ERROR: these credentials cannot read instance types or service quotas, so this
check cannot tell you whether you have GPU capacity. That is a permissions
problem, not a quota problem. A quota of 0 shown above may simply mean the
value could not be read.

Caller: $(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo unknown)

The scaffold needs, at minimum:
  ec2:Describe*                    instance types, images, VPCs, security groups
  ec2:CreateKeyPair, DeleteKeyPair
  ec2:CreateSecurityGroup, AuthorizeSecurityGroupIngress, DeleteSecurityGroup
  ec2:RunInstances, TerminateInstances, CreateTags
  ssm:GetParameter                 Deep Learning AMI lookup
  servicequotas:GetServiceQuota, RequestServiceQuotaIncrease

Quickest fix: attach AmazonEC2FullAccess, ServiceQuotasReadOnlyAccess and
AmazonSSMReadOnlyAccess to this IAM user, or use credentials that already have
them. See README.md, "IAM permissions".
MSG
  exit 1
fi

echo
echo "==> GPU instance types offered in ${REGION}"
aws ec2 describe-instance-type-offerings --location-type region \
  --filters "Name=instance-type,Values=g6.*,g5.*,g4dn.*" \
  --query 'InstanceTypeOfferings[].InstanceType' --output text 2>/dev/null \
  | tr '\t' '\n' | sort | head -12 | sed 's/^/    /' || echo "    (could not list)"

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
