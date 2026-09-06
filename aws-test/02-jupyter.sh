#!/usr/bin/env bash
# Installs JupyterLab into the AMI's PyTorch environment and starts it bound to
# localhost on the instance. It is never exposed to the network; 03-tunnel.sh
# forwards a local port over SSH.
source "$(dirname "$0")/config.sh"

PUBLIC_IP="$(cat "${STATE_DIR}/public-ip")"
SSH=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${KEY_FILE}" "ubuntu@${PUBLIC_IP}")

TOKEN_FILE="${STATE_DIR}/jupyter-token"
if [[ ! -f "${TOKEN_FILE}" ]]; then
  head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' > "${TOKEN_FILE}"
  chmod 600 "${TOKEN_FILE}"
fi
TOKEN="$(cat "${TOKEN_FILE}")"

echo "==> Installing JupyterLab"
"${SSH[@]}" "source /opt/pytorch/bin/activate 2>/dev/null || true; \
  pip install --quiet jupyterlab 2>&1 | tail -2"

echo "==> Copying notebooks and benchmark"
scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${KEY_FILE}" \
  "$(dirname "$0")/notebooks/"*.ipynb "$(dirname "$0")/bench/"*.py \
  "ubuntu@${PUBLIC_IP}:/home/ubuntu/"

echo "==> Starting JupyterLab bound to 127.0.0.1"
# --ip=127.0.0.1 matters: without it Jupyter listens on all interfaces, and the
# only thing keeping it private would be the security group.
"${SSH[@]}" "pkill -f jupyter-lab || true; \
  source /opt/pytorch/bin/activate 2>/dev/null || true; \
  nohup jupyter lab --no-browser --ip=127.0.0.1 --port=8888 \
    --IdentityProvider.token='${TOKEN}' \
    --ServerApp.root_dir=/home/ubuntu \
    > /home/ubuntu/jupyter.log 2>&1 & sleep 5; tail -3 /home/ubuntu/jupyter.log"

echo
echo "Jupyter is running. Start the tunnel with:  ./03-tunnel.sh"
