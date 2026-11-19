#!/usr/bin/env bash
# Phase 2, step 1: kubeadm init on the control plane, executed through SSM Run Command.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require CP_ID

log "Render k8s/kubeadm-config.yaml (control plane $CP_IP, pods $POD_CIDR, services $SERVICE_CIDR)"
KUBEADM_CONFIG_B64=$(sed \
  -e "s#__CP_IP__#${CP_IP}#g" \
  -e "s#__CLUSTER__#${CLUSTER}#g" \
  -e "s#__POD_CIDR__#${POD_CIDR}#g" \
  -e "s#__SERVICE_CIDR__#${SERVICE_CIDR}#g" \
  "$ROOT_DIR/k8s/kubeadm-config.yaml" | b64)

log "kubeadm init on $CP_ID (2-4 minutes)"
ssm_script "$CP_ID" "$ROOT_DIR/scripts/node/cp-init.sh" "$KUBEADM_CONFIG_B64"

log "Control plane initialised. Next: ./scripts/06-install-cni.sh"
