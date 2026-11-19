#!/usr/bin/env bash
# Phase 2, step 3: join both workers, approve kubelet serving CSRs, label the workers.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require CP_ID
require W1_ID
require W2_ID

log "Create a join token on the control plane (valid for 1 hour)"
JOIN_OUTPUT=$(ssm_script "$CP_ID" "$ROOT_DIR/scripts/node/join-command.sh")
JOIN_CMD=$(printf '%s\n' "$JOIN_OUTPUT" | grep -m1 '^kubeadm join') ||
  die "Could not find a 'kubeadm join' line in the output:
$JOIN_OUTPUT"

# Format: kubeadm join <endpoint> --token <token> --discovery-token-ca-cert-hash <hash>
read -r _ _ JOIN_ENDPOINT _ JOIN_TOKEN _ JOIN_HASH <<<"$JOIN_CMD"
[[ -n "$JOIN_ENDPOINT" && -n "$JOIN_TOKEN" && -n "$JOIN_HASH" ]] ||
  die "Could not parse the join command: $JOIN_CMD"
info "endpoint $JOIN_ENDPOINT"

log "Join worker1 ($W1_ID)"
ssm_script "$W1_ID" "$ROOT_DIR/scripts/node/worker-join.sh" "$JOIN_ENDPOINT" "$JOIN_TOKEN" "$JOIN_HASH"

log "Join worker2 ($W2_ID)"
ssm_script "$W2_ID" "$ROOT_DIR/scripts/node/worker-join.sh" "$JOIN_ENDPOINT" "$JOIN_TOKEN" "$JOIN_HASH"

log "Give the kubelets 30 s to request their serving certificates"
sleep 30

log "Approve kubelet serving CSRs and label workers"
ssm_script "$CP_ID" "$ROOT_DIR/scripts/node/post-join.sh"

cat <<EOF

Workers joined. If a node still shows NotReady, wait a minute for Calico to start on it.
If 'kubectl logs' later fails with a TLS error, a CSR was not there yet; approve it with:
    ./scripts/ssm.sh script cp scripts/node/post-join.sh

Next: ./scripts/08-smoke-test.sh
EOF
