#!/usr/bin/env bash
# Forwards a local port to Jupyter over SSH. Nothing listens publicly.
source "$(dirname "$0")/config.sh"

PUBLIC_IP="$(cat "${STATE_DIR}/public-ip")"
TOKEN="$(cat "${STATE_DIR}/jupyter-token")"

echo
echo "Open this URL:"
echo "  http://127.0.0.1:${LOCAL_PORT}/lab?token=${TOKEN}"
echo
echo "Ctrl-C stops the tunnel. The instance and Jupyter keep running."
echo

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${KEY_FILE}" \
  -N -L "127.0.0.1:${LOCAL_PORT}:127.0.0.1:8888" "ubuntu@${PUBLIC_IP}"
