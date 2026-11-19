#!/usr/bin/env bash
# Phase 1, step 2: IAM role and instance profile for the nodes.
# The only managed policy attached is AmazonSSMManagedInstanceCore, which is what lets the
# SSM agent register the instance so you can use Session Manager and Run Command (no SSH).
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROLE_NAME="${CLUSTER}-node-role"
PROFILE_NAME="${CLUSTER}-node-profile"
SSM_POLICY_ARN="arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

log "IAM role $ROLE_NAME"
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  info "exists"
else
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --description "Nodes of ${CLUSTER}: SSM access only" \
    --tags "Key=project,Value=${CLUSTER}" >/dev/null
  info "created"
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$SSM_POLICY_ARN"
info "attached AmazonSSMManagedInstanceCore"

log "Instance profile $PROFILE_NAME"
if aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
  info "exists"
else
  aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" \
    --tags "Key=project,Value=${CLUSTER}" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME"
  info "created; waiting 15 s for IAM propagation"
  sleep 15
fi

save IAM_ROLE_NAME "$ROLE_NAME"
save IAM_PROFILE_NAME "$PROFILE_NAME"

log "IAM ready. Next: ./scripts/03-security-groups.sh"
