# Wraps the Terraform in envs/dev. Every target is safe to re-run.
SHELL := /bin/bash
ENV   := envs/dev
TF    := terraform -chdir=$(ENV)

# Read from the state rather than duplicated here, so `make forward` works
# without repeating the namespace.
NS = $(shell $(TF) output -raw namespace 2>/dev/null || echo dai)

.PHONY: help bootstrap init fmt validate plan up scale forward token jobs logs down notebooks

help:
	@echo "make bootstrap  - create the GCS state bucket and enable APIs (once, needs PROJECT_ID)"
	@echo "make init       - terraform init against that bucket (needs BUCKET)"
	@echo "make fmt        - terraform fmt -recursive"
	@echo "make validate   - terraform validate"
	@echo "make plan       - show what an apply would change"
	@echo "make up         - apply: cluster, GPU pool, Jupyter, guardrails"
	@echo "make scale      - change the topology, e.g. make scale NODES=2 GPUS=2"
	@echo "make forward    - port-forward Jupyter to localhost:8888"
	@echo "make token      - print the Jupyter token"
	@echo "make jobs       - submit a torchrun Job, e.g. make jobs SCRIPT=train_ddp_cifar10.py NNODES=2 NPROC=2"
	@echo "make logs       - follow rank 0's logs"
	@echo "make notebooks  - regenerate notebooks/*.ipynb from notebooks/*.py"
	@echo "make down       - destroy everything"

bootstrap:
	PROJECT_ID=$(PROJECT_ID) ./bootstrap/bootstrap.sh

init:
	$(TF) init -backend-config=bucket=$(BUCKET)

fmt:
	terraform fmt -recursive

validate:
	$(TF) validate

plan:
	$(TF) plan

# Two applies on purpose. The kubernetes provider is configured from the
# cluster's own endpoint, so on a first run that endpoint does not exist while
# the plan is being built. Targeting the cluster first makes it exist.
up:
	$(TF) apply -target=module.gke -auto-approve
	$(TF) apply -auto-approve
	@echo
	@echo "Jupyter: make forward, then http://localhost:8888/lab?token=$$($(TF) output -raw jupyter_token)"

NODES ?= 1
GPUS  ?= 2
scale:
	$(TF) apply -auto-approve -var node_count=$(NODES) -var gpus_per_node=$(GPUS)
	@echo "Now $(NODES) node(s) x $(GPUS) GPU = $$(( $(NODES) * $(GPUS) )) GPUs"

forward:
	kubectl port-forward -n $(NS) svc/jupyter 8888:8888

token:
	@$(TF) output -raw jupyter_token; echo

SCRIPT ?= train_ddp_cifar10.py
NNODES ?= 1
NPROC  ?= 2
jobs:
	kubectl delete job ddp-train -n $(NS) --ignore-not-found
	sed -e 's|{{SCRIPT}}|$(SCRIPT)|g' \
	    -e 's|{{NNODES}}|$(NNODES)|g' \
	    -e 's|{{NPROC}}|$(NPROC)|g' \
	    -e 's|{{BUCKET}}|$(shell $(TF) output -raw artifacts_bucket)|g' \
	    jobs/torchrun-job.yaml | kubectl apply -n $(NS) -f -
	@echo "Submitted. make logs"

logs:
	kubectl logs -n $(NS) -f job/ddp-train --all-containers --prefix

notebooks:
	python3 tools/py_to_ipynb.py notebooks/*.py

# Scale the GPU pool down first: destroying it as part of the whole graph can
# race the cluster teardown and leave orphaned nodes billing.
down:
	$(TF) apply -auto-approve -var node_count=0
	$(TF) destroy -auto-approve
