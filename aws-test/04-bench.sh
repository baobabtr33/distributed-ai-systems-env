#!/usr/bin/env bash
# Runs bench/ddp_allreduce.py on the instance twice - once on a single GPU for a
# baseline, once across every GPU the instance has - and prints the scaling
# summary. Ten minutes of Spot time, so it is a separate step from `make up`.
source "$(dirname "$0")/config.sh"

PUBLIC_IP="$(cat "${STATE_DIR}/public-ip")"
SSH=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${KEY_FILE}" "ubuntu@${PUBLIC_IP}")

# Ask the instance rather than deriving it from INSTANCE_TYPE: the two disagree
# if the type was overridden between launch and now.
NGPU="$("${SSH[@]}" "nvidia-smi --list-gpus | wc -l" | tr -d ' \r')"
echo "==> ${NGPU} GPU(s) on the instance"

if [[ "${NGPU}" -lt 2 ]]; then
  echo "    Only one GPU, so there is no scaling to measure. Running the baseline alone." >&2
fi

ACTIVATE='source /opt/pytorch/bin/activate 2>/dev/null || true'

echo
echo "==> Baseline, 1 GPU"
"${SSH[@]}" "${ACTIVATE}; cd /home/ubuntu && \
  torchrun --nproc_per_node=1 ddp_allreduce.py --tag baseline --json-out result_1gpu.json"

if [[ "${NGPU}" -ge 2 ]]; then
  echo
  echo "==> Scaled, ${NGPU} GPUs"
  # --standalone keeps rendezvous on localhost; this is one node.
  "${SSH[@]}" "${ACTIVATE}; cd /home/ubuntu && \
    torchrun --standalone --nproc_per_node=${NGPU} ddp_allreduce.py \
      --tag scaled --json-out result_${NGPU}gpu.json"

  echo
  echo "==> Summary"
  "${SSH[@]}" "${ACTIVATE}; cd /home/ubuntu && \
    python summarize.py result_1gpu.json result_${NGPU}gpu.json"

  echo
  echo "==> Copying results back to .state/"
  scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${KEY_FILE}" \
    "ubuntu@${PUBLIC_IP}:/home/ubuntu/result_*.json" "${STATE_DIR}/"
  ls -1 "${STATE_DIR}"/result_*.json
fi
