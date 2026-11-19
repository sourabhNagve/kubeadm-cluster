SHELL := /usr/bin/env bash

# Terraform binary and extra arguments, for example: make tf-apply TF_ARGS=-auto-approve
# OpenTofu works too: make tf-up TF=tofu
TF ?= terraform
TF_ARGS ?=

.DEFAULT_GOAL := help
.PHONY: help infra network iam sg instances status cluster control-plane cni workers approve test down lint \
	tf-init tf-plan tf-apply tf-sync tf-up tf-destroy tf-fmt tf-validate

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  %-14s %s\n", $$1, $$2}'

# ---- Phase 1 (Option A): AWS infrastructure with Terraform ----
tf-init: ## Terraform: download providers
	$(TF) -chdir=terraform init

tf-plan: ## Terraform: show what would be created
	$(TF) -chdir=terraform plan

tf-apply: ## Terraform: create VPC, IAM, security groups, instances
	$(TF) -chdir=terraform apply $(TF_ARGS)

tf-sync: ## Copy Terraform outputs into .state/ for the cluster scripts
	TF_BIN=$(TF) ./scripts/tf-sync.sh

tf-up: tf-apply tf-sync ## Terraform: apply, then sync (Phase 1 in one step)

tf-destroy: ## Terraform: delete everything Terraform created
	$(TF) -chdir=terraform destroy $(TF_ARGS)
	rm -f .state/cluster.env .state/kubeconfig .state/node-userdata.sh

tf-fmt: ## Terraform: format .tf files
	$(TF) -chdir=terraform fmt -recursive

tf-validate: ## Terraform: fmt check + validate (needs `make tf-init` first)
	$(TF) -chdir=terraform fmt -check -recursive
	$(TF) -chdir=terraform validate

# ---- Phase 1 (Option B): AWS infrastructure with AWS CLI scripts ----
infra: network iam sg instances ## AWS CLI: VPC, IAM, security groups, instances

network: ## VPC, subnets, IGW, NAT gateway, route tables
	./scripts/01-network.sh

iam: ## Node IAM role + instance profile (SSM access)
	./scripts/02-iam.sh

sg: ## Security groups and rules
	./scripts/03-security-groups.sh

instances: ## Launch 1 control plane + 2 workers
	./scripts/04-launch-instances.sh

status: ## Show which instances are registered with SSM (wait for Online before phase 2)
	./scripts/ssm.sh status

# ---- Phase 2: Kubernetes (runs on the nodes through SSM; same for both options) ----
cluster: control-plane cni workers test ## Phase 2: everything below, in order

control-plane: ## kubeadm init on the control plane
	./scripts/05-init-control-plane.sh

cni: ## Install Calico
	./scripts/06-install-cni.sh

workers: ## Join workers and approve kubelet serving CSRs
	./scripts/07-join-workers.sh

approve: ## Re-run CSR approval and worker labelling (if kubectl logs shows TLS errors)
	./scripts/ssm.sh script cp scripts/node/post-join.sh

test: ## Smoke test (scheduling, NodePort, DNS, logs)
	./scripts/08-smoke-test.sh

# ---- Cleanup / quality ----
down: ## AWS CLI path only: destroy everything the scripts created (Terraform users: tf-destroy)
	./scripts/99-teardown.sh

lint: ## bash -n and shellcheck on all scripts
	@find scripts -name '*.sh' -exec bash -n {} \; -print
	@command -v shellcheck >/dev/null && shellcheck -x scripts/*.sh scripts/node/*.sh || echo "shellcheck not installed, skipped"
