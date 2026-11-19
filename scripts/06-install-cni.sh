#!/usr/bin/env bash
# Phase 2, step 2: install Calico (VXLAN) through the Tigera operator.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require CP_ID

log "Render k8s/calico-installation.yaml (pod CIDR $POD_CIDR)"
INSTALLATION_B64=$(sed -e "s#__POD_CIDR__#${POD_CIDR}#g" \
  "$ROOT_DIR/k8s/calico-installation.yaml" | b64)

log "Install Calico on $CP_ID (3-5 minutes)"
ssm_script "$CP_ID" "$ROOT_DIR/scripts/node/install-calico.sh" "$INSTALLATION_B64" "${CALICO_VERSION:-}"

log "CNI installed. Next: ./scripts/07-join-workers.sh"
