#!/usr/bin/env bash
# Terminates the instance and removes the key pair and security group.
# EBS volumes have DeleteOnTermination set, so they go with the instance.
source "$(dirname "$0")/config.sh"

echo "This terminates every instance tagged ${TAG_KEY}=${TAG_VALUE} in ${REGION},"
echo "and deletes key pair ${KEY_NAME} and security group ${SG_NAME}."
read -r -p "Type the instance name to confirm: " CONFIRM
if [[ "${CONFIRM}" != "${NAME}" ]]; then
  echo "Aborted."
  exit 1
fi

IDS="$(aws ec2 describe-instances \
  --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)"

if [[ -n "${IDS}" ]]; then
  echo "==> Terminating ${IDS}"
  aws ec2 terminate-instances --instance-ids ${IDS} >/dev/null
  aws ec2 wait instance-terminated --instance-ids ${IDS}
else
  echo "==> No running instances tagged ${TAG_KEY}=${TAG_VALUE}"
fi

# The security group cannot be deleted until its instances are fully gone, which
# is why this waits above rather than firing both and hoping.
aws ec2 delete-security-group --group-name "${SG_NAME}" 2>/dev/null \
  && echo "==> Deleted security group ${SG_NAME}" \
  || echo "==> Security group ${SG_NAME} not deleted (may not exist)"

aws ec2 delete-key-pair --key-name "${KEY_NAME}" 2>/dev/null \
  && echo "==> Deleted key pair ${KEY_NAME}"
rm -f "${KEY_FILE}" "${STATE_DIR}/instance-id" "${STATE_DIR}/public-ip" "${STATE_DIR}/jupyter-token"

echo
echo "Done. Confirm nothing is left:"
echo "  aws ec2 describe-instances --filters Name=tag:${TAG_KEY},Values=${TAG_VALUE} \\"
echo "    --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text"
echo "  aws ec2 describe-volumes --filters Name=tag:${TAG_KEY},Values=${TAG_VALUE} --output text"
