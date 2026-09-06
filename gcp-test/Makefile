# Sample: one GKE node with one NVIDIA L4, running JupyterLab.
# Every target is a thin wrapper over the numbered scripts, which are the source of truth.

SHELL := /bin/bash
NAMESPACE ?= jupyter

.PHONY: help preflight up jupyter forward status logs shell down all gpu multi-gpu pools drop-pools

help:
	@echo "make preflight  - enable APIs, show GPU quota"
	@echo "make up         - create the GKE cluster with one GPU node (~8 min)"
	@echo "make jupyter    - deploy the JupyterLab pod onto the GPU"
	@echo "make forward    - localhost tunnel to Jupyter, prints the URL with token"
	@echo "make gpu        - add a 1x L4 node pool and move Jupyter onto it"
	@echo "make multi-gpu  - add a 2x L4 node, then benchmark 1 GPU vs 2 GPU"
	@echo "make all        - preflight + up + jupyter"
	@echo "make pools      - list node pools and their GPU allocation"
	@echo "make drop-pools - delete the GPU node pools, keep the cluster"
	@echo "make status     - node, pod and GPU allocation"
	@echo "make logs       - tail the Jupyter pod logs"
	@echo "make shell      - shell inside the Jupyter pod"
	@echo "make down       - DELETE the cluster (this is the off switch for billing)"

preflight:
	./00-preflight.sh

up:
	./01-create-cluster.sh

jupyter:
	./02-deploy-jupyter.sh

forward:
	./03-port-forward.sh

all: preflight up jupyter

gpu:
	./04-gpu.sh

multi-gpu:
	./05-multi-gpu.sh

pools:
	@gcloud container node-pools list --cluster $${CLUSTER:-gpu-sample} --zone $${ZONE:-us-central1-a} \
	  --format="table(name,config.machineType,config.accelerators[0].acceleratorCount,initialNodeCount)"
	@echo
	@kubectl get nodes -L cloud.google.com/gke-nodepool \
	  -o custom-columns=NAME:.metadata.name,POOL:.metadata.labels.cloud\\.google\\.com/gke-nodepool,GPU:.status.allocatable.nvidia\\.com/gpu

# Deleting the pool is the fast way to stop GPU spend without losing the cluster,
# the PVC, or the notebooks on it.
drop-pools:
	-gcloud container node-pools delete gpu-pool --cluster $${CLUSTER:-gpu-sample} --zone $${ZONE:-us-central1-a} --quiet
	-gcloud container node-pools delete gpu-pool-multi --cluster $${CLUSTER:-gpu-sample} --zone $${ZONE:-us-central1-a} --quiet

status:
	@kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu
	@echo
	@kubectl -n $(NAMESPACE) get pods -o wide

logs:
	kubectl -n $(NAMESPACE) logs -f deploy/jupyter

shell:
	kubectl -n $(NAMESPACE) exec -it deploy/jupyter -- bash

down:
	./99-teardown.sh
