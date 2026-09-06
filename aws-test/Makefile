# aws-test: one EC2 GPU instance running JupyterLab over an SSH tunnel.
# The numbered scripts are the source of truth; these are thin wrappers.

SHELL := /bin/bash

.PHONY: help preflight up jupyter tunnel status ssh logs down all

help:
	@echo "make preflight - check G-instance vCPU quota and Spot price"
	@echo "make up        - launch the GPU instance, wait for SSH, run nvidia-smi"
	@echo "make jupyter   - install JupyterLab, copy notebooks, start it on localhost"
	@echo "make tunnel    - SSH tunnel to Jupyter, prints the URL with token"
	@echo "make all       - preflight + up + jupyter"
	@echo "make status    - instance id, state, type, public IP"
	@echo "make ssh       - shell on the instance"
	@echo "make logs      - tail the Jupyter log"
	@echo "make down      - TERMINATE the instance and delete the key and SG"

preflight:
	./00-preflight.sh

up:
	./01-launch.sh

jupyter:
	./02-jupyter.sh

tunnel:
	./03-tunnel.sh

all: preflight up jupyter

status:
	@aws ec2 describe-instances \
	  --filters "Name=tag:aws-test,Values=$${NAME:-gpu-test}" \
	  --query 'Reservations[].Instances[].[InstanceId,State.Name,InstanceType,PublicIpAddress]' \
	  --output table

ssh:
	@ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	  -i $${KEY_FILE:-./gpu-test-key.pem} ubuntu@$$(cat .state/public-ip)

logs:
	@ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	  -i $${KEY_FILE:-./gpu-test-key.pem} ubuntu@$$(cat .state/public-ip) \
	  "tail -f /home/ubuntu/jupyter.log"

down:
	./99-teardown.sh
