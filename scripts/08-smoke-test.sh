#!/usr/bin/env bash
# Phase 2, step 4: end-to-end smoke test (scheduling, NodePort, DNS, kubelet certs).
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require CP_ID

MANIFEST_B64=$(b64 <"$ROOT_DIR/k8s/smoke-test.yaml")

log "Run the smoke test on the control plane"
ssm_script "$CP_ID" "$ROOT_DIR/scripts/node/smoke-test.sh" "$MANIFEST_B64"

log "All checks passed. Tear everything down when you are done: ./scripts/99-teardown.sh"
