#!/usr/bin/env bash
# Copies Terraform outputs into .state/cluster.env so the SSM cluster scripts (05 to 08, ssm.sh)
# work on top of Terraform-built infrastructure. Run it after every `terraform apply`
# (`make tf-up` does both). Safe to re-run.
#
#   TF_BIN=tofu ./scripts/tf-sync.sh     use OpenTofu instead of Terraform
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT_DIR/terraform"
TF_BIN="${TF_BIN:-terraform}"

# The cluster scripts always read config.env (Kubernetes settings such as the pod CIDR live
# there). Create it from the example on first use so a Terraform-only user is not blocked.
if [[ ! -f "${CONFIG_FILE:-$ROOT_DIR/config.env}" ]]; then
  cp "$ROOT_DIR/config.env.example" "${CONFIG_FILE:-$ROOT_DIR/config.env}"
  echo "    created config.env from config.env.example"
fi

# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

command -v "$TF_BIN" >/dev/null 2>&1 || die "'$TF_BIN' not found. Install Terraform (or set TF_BIN=tofu)."

# Refuse to mix the two provisioning paths: state written by the AWS CLI scripts describes
# different resources than Terraform manages.
if [[ -n "${VPC_ID:-}" && "${MANAGED_BY:-}" != "terraform" ]]; then
  die ".state/cluster.env describes resources created by the AWS CLI scripts (VPC $VPC_ID).
Delete them first with ./scripts/99-teardown.sh, then run this again."
fi

# tfo NAME: print one Terraform output as a raw string.
tfo() {
  "$TF_BIN" -chdir="$TF_DIR" output -raw "$1"
}

log "Read Terraform outputs from $TF_DIR"
tfo cluster >/dev/null 2>&1 ||
  die "No Terraform outputs found. Run 'make tf-apply' first (and make sure it finished without errors)."

save MANAGED_BY terraform
save CLUSTER "$(tfo cluster)"
save AWS_REGION "$(tfo aws_region)"
save VPC_ID "$(tfo vpc_id)"
save PUB_SUBNET "$(tfo public_subnet_id)"
save PRIV_SUBNET "$(tfo private_subnet_id)"
save NAT_ID "$(tfo nat_gateway_id)"
save CP_SG "$(tfo cp_security_group_id)"
save WK_SG "$(tfo worker_security_group_id)"
save CP_ID "$(tfo cp_instance_id)"
save W1_ID "$(tfo worker1_instance_id)"
save W2_ID "$(tfo worker2_instance_id)"
save CP_IP "$(tfo cp_private_ip)"
save AMI "$(tfo ami_id)"

log "Wrote $STATE_FILE"
info "CLUSTER=$CLUSTER  AWS_REGION=$AWS_REGION  VPC_ID=$VPC_ID"
info "CP_ID=$CP_ID  W1_ID=$W1_ID  W2_ID=$W2_ID  CP_IP=$CP_IP"

cat <<'EOF'

Next:
    make status      # wait until all three instances show Online (3-5 minutes after apply)
    make cluster     # kubeadm init, Calico, join workers, smoke test
EOF
