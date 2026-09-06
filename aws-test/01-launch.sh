#!/usr/bin/env bash
# Launches one GPU instance from the AWS Deep Learning AMI, which ships the
# NVIDIA driver, CUDA and PyTorch already installed. Building that from a bare
# Ubuntu AMI takes 20 minutes of driver compilation for no benefit here.
source "$(dirname "$0")/config.sh"

# --- key pair -------------------------------------------------------------
if [[ -f "${KEY_FILE}" ]] && aws ec2 describe-key-pairs --key-names "${KEY_NAME}" >/dev/null 2>&1; then
  echo "==> Key pair ${KEY_NAME} already exists"
else
  # A key that exists in AWS without the local .pem is useless: the private half
  # is only returned at creation time. Delete and recreate rather than inherit it.
  aws ec2 delete-key-pair --key-name "${KEY_NAME}" >/dev/null 2>&1 || true
  echo "==> Creating key pair ${KEY_NAME}"
  aws ec2 create-key-pair --key-name "${KEY_NAME}" \
    --query 'KeyMaterial' --output text > "${KEY_FILE}"
  chmod 400 "${KEY_FILE}"
fi

# --- security group -------------------------------------------------------
VPC_ID="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)"

SG_ID="$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${SG_NAME}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")"

if [[ "${SG_ID}" == "None" || -z "${SG_ID}" ]]; then
  echo "==> Creating security group ${SG_NAME}"
  SG_ID="$(aws ec2 create-security-group --group-name "${SG_NAME}" \
    --description "aws-test GPU instance: SSH only" --vpc-id "${VPC_ID}" \
    --query 'GroupId' --output text)"

  # SSH from this machine's public address only. Jupyter is never exposed: it is
  # reached through an SSH tunnel, so no port 8888 rule exists anywhere.
  MY_IP="$(curl -s --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')"
  aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" \
    --protocol tcp --port 22 --cidr "${MY_IP}/32" >/dev/null
  echo "    SSH allowed from ${MY_IP}/32 only"
fi

# --- AMI ------------------------------------------------------------------
# Resolve the current Deep Learning AMI from SSM rather than hardcoding an ID,
# which would rot and is region-specific.
AMI_ID="$(aws ssm get-parameter \
  --name /aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id \
  --query 'Parameter.Value' --output text 2>/dev/null || echo "")"

if [[ -z "${AMI_ID}" || "${AMI_ID}" == "None" ]]; then
  echo "==> SSM lookup failed, searching for a Deep Learning AMI by name"
  AMI_ID="$(aws ec2 describe-images --owners amazon \
    --filters "Name=name,Values=Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)*" \
              "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)"
fi
echo "==> AMI ${AMI_ID}"

# --- launch ---------------------------------------------------------------
MARKET_OPTS=()
if [[ "${SPOT}" == "true" ]]; then
  # one-time, no interruption behaviour other than terminate: this is a scratch box.
  MARKET_OPTS=(--instance-market-options '{"MarketType":"spot","SpotOptions":{"SpotInstanceType":"one-time"}}')
fi

echo "==> Launching ${INSTANCE_TYPE}"
INSTANCE_ID="$(aws ec2 run-instances \
  --image-id "${AMI_ID}" \
  --instance-type "${INSTANCE_TYPE}" \
  --key-name "${KEY_NAME}" \
  --security-group-ids "${SG_ID}" \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${VOLUME_SIZE},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=${TAG_KEY},Value=${TAG_VALUE}},{Key=Name,Value=${NAME}}]" \
    "ResourceType=volume,Tags=[{Key=${TAG_KEY},Value=${TAG_VALUE}}]" \
  "${MARKET_OPTS[@]}" \
  --query 'Instances[0].InstanceId' --output text)"

echo "${INSTANCE_ID}" > "${STATE_DIR}/instance-id"
echo "    instance ${INSTANCE_ID}"

echo "==> Waiting for the instance to run"
aws ec2 wait instance-running --instance-ids "${INSTANCE_ID}"

PUBLIC_IP="$(aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
echo "${PUBLIC_IP}" > "${STATE_DIR}/public-ip"
echo "    public IP ${PUBLIC_IP}"

echo "==> Waiting for SSH (the Deep Learning AMI takes a minute or two to finish booting)"
for i in $(seq 1 40); do
  if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
         -o ConnectTimeout=5 -i "${KEY_FILE}" "ubuntu@${PUBLIC_IP}" true 2>/dev/null; then
    echo "    SSH is up"
    break
  fi
  echo "    [${i}/40] not yet..."
  sleep 10
done

echo
echo "==> GPU as the instance sees it"
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "${KEY_FILE}" "ubuntu@${PUBLIC_IP}" "nvidia-smi"

echo
echo "Next:  ./02-jupyter.sh"
