#!/usr/bin/env bash
# Runs ON the control-plane node, as root, through SSM (scripts/07-join-workers.sh, `make approve`).
#
# 1. Approves pending kubelet SERVING certificate requests. We set serverTLSBootstrap: true, so
#    each kubelet asks the cluster CA for its serving cert. Until that CSR is approved,
#    `kubectl logs` and `kubectl exec` fail with TLS errors. Only the kubernetes.io/kubelet-serving
#    signer is approved here; anything else is left for a human to review.
# 2. Labels the workers with the conventional role label.
#
# Safe to re-run. The CSR appears shortly after a node joins, so run it again if it finds none.
set -euo pipefail

export KUBECONFIG=/etc/kubernetes/admin.conf

PENDING=$(kubectl get csr --no-headers | awk '$3=="kubernetes.io/kubelet-serving" && $NF=="Pending" {print $1}')
if [[ -n "$PENDING" ]]; then
  echo "Approving kubelet serving CSRs:"
  echo "$PENDING"
  # shellcheck disable=SC2086
  kubectl certificate approve $PENDING
else
  echo "No pending kubelet serving CSRs (yet)."
fi

kubectl label nodes -l '!node-role.kubernetes.io/control-plane' node-role.kubernetes.io/worker= --overwrite

echo
kubectl get nodes -o wide
