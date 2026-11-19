#!/usr/bin/env bash
# Destroys everything this repo created, in dependency order, using the IDs in .state/cluster.env.
#
#   ./scripts/99-teardown.sh          asks you to type the cluster name first
#   ./scripts/99-teardown.sh --yes    no prompt (CI / scripted use)
#
# Safe to re-run: an ID is removed from the state file only after its resource is really gone,
# so a second run retries only what is left. AWS releases some network interfaces a minute or
# two after the instances and the NAT gateway are gone; if a step reports DependencyViolation,
# wait and run the script again.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ "${MANAGED_BY:-}" == "terraform" ]]; then
  die "This infrastructure is managed by Terraform. Deleting it here would leave Terraform's state
out of date. Use: make tf-destroy"
fi

if [[ "${1:-}" != "--yes" ]]; then
  read -r -p "This deletes ALL resources of '${CLUSTER}' in ${AWS_REGION}. Type the cluster name to continue: " ANSWER
  [[ "$ANSWER" == "$CLUSTER" ]] || die "Aborted."
fi

FAILED=0

# try CMD...: run a command; on failure print a warning, remember it, and keep going.
try() {
  if ! "$@"; then
    echo "    WARN: failed: $*" >&2
    FAILED=1
  fi
}

# drop STATE_KEY CMD...: run a command; forget STATE_KEY only if it succeeded.
drop() {
  local key=$1
  shift
  if "$@"; then
    unsave "$key"
  else
    echo "    WARN: failed: $*" >&2
    FAILED=1
  fi
}

# revoke_ingress SG: remove every ingress rule, so security groups that reference each other
# can be deleted.
revoke_ingress() {
  local rule_ids
  # shellcheck disable=SC2016  # backticks are JMESPath literals, not shell substitution
  rule_ids=$(aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$1" \
    --query 'SecurityGroupRules[?IsEgress==`false`].SecurityGroupRuleId' --output text)
  if [[ -n "$rule_ids" ]]; then
    # shellcheck disable=SC2086
    aws ec2 revoke-security-group-ingress --group-id "$1" --security-group-rule-ids $rule_ids >/dev/null
  fi
}

log "Instances"
if [[ -n "${CP_ID:-}" ]]; then try aws ec2 terminate-instances --instance-ids "$CP_ID" >/dev/null; fi
if [[ -n "${W1_ID:-}" ]]; then try aws ec2 terminate-instances --instance-ids "$W1_ID" >/dev/null; fi
if [[ -n "${W2_ID:-}" ]]; then try aws ec2 terminate-instances --instance-ids "$W2_ID" >/dev/null; fi
if [[ -n "${CP_ID:-}" ]]; then drop CP_ID aws ec2 wait instance-terminated --instance-ids "$CP_ID"; fi
if [[ -n "${W1_ID:-}" ]]; then drop W1_ID aws ec2 wait instance-terminated --instance-ids "$W1_ID"; fi
if [[ -n "${W2_ID:-}" ]]; then drop W2_ID aws ec2 wait instance-terminated --instance-ids "$W2_ID"; fi

log "NAT gateway and Elastic IP"
if [[ -n "${NAT_ID:-}" ]]; then
  try aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_ID" >/dev/null
  drop NAT_ID aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$NAT_ID"
fi
if [[ -n "${EIP_ALLOC:-}" ]]; then drop EIP_ALLOC aws ec2 release-address --allocation-id "$EIP_ALLOC"; fi

log "Subnets and route tables"
if [[ -n "${PRIV_SUBNET:-}" ]]; then drop PRIV_SUBNET aws ec2 delete-subnet --subnet-id "$PRIV_SUBNET"; fi
if [[ -n "${PUB_SUBNET:-}" ]]; then drop PUB_SUBNET aws ec2 delete-subnet --subnet-id "$PUB_SUBNET"; fi
if [[ -n "${PRIV_RT:-}" ]]; then drop PRIV_RT aws ec2 delete-route-table --route-table-id "$PRIV_RT"; fi
if [[ -n "${PUB_RT:-}" ]]; then drop PUB_RT aws ec2 delete-route-table --route-table-id "$PUB_RT"; fi

log "Security groups"
if [[ -n "${CP_SG:-}" ]]; then try revoke_ingress "$CP_SG"; fi
if [[ -n "${WK_SG:-}" ]]; then try revoke_ingress "$WK_SG"; fi
if [[ -n "${WK_SG:-}" ]]; then drop WK_SG aws ec2 delete-security-group --group-id "$WK_SG"; fi
if [[ -n "${CP_SG:-}" ]]; then drop CP_SG aws ec2 delete-security-group --group-id "$CP_SG"; fi

log "Internet gateway and VPC"
if [[ -n "${IGW_ID:-}" && -n "${VPC_ID:-}" ]]; then
  try aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
  drop IGW_ID aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID"
fi
if [[ -n "${VPC_ID:-}" ]]; then drop VPC_ID aws ec2 delete-vpc --vpc-id "$VPC_ID"; fi

log "IAM role and instance profile"
ROLE_NAME="${CLUSTER}-node-role"
PROFILE_NAME="${CLUSTER}-node-profile"
if aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
  try aws iam remove-role-from-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME"
  try aws iam delete-instance-profile --instance-profile-name "$PROFILE_NAME"
fi
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  try aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  try aws iam delete-role --role-name "$ROLE_NAME"
fi

if [[ "$FAILED" -ne 0 ]]; then
  echo
  echo "Some steps failed (usually DependencyViolation while AWS releases network interfaces)."
  echo "Wait 1-2 minutes and run this script again; it only retries what is left."
  exit 1
fi

unsave IAM_ROLE_NAME
unsave IAM_PROFILE_NAME
unsave AMI
log "Everything is deleted."
