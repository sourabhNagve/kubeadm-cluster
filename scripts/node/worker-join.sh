#!/usr/bin/env bash
# Runs ON a worker node, as root, through SSM (scripts/07-join-workers.sh).
# $1 = API endpoint (host:port)   $2 = bootstrap token   $3 = CA cert hash (sha256:...)
set -euo pipefail

ENDPOINT="${1:?API endpoint is required}"
TOKEN="${2:?token is required}"
CA_HASH="${3:?CA cert hash is required}"

echo "Waiting for node preparation (cloud-init user-data) to finish..."
cloud-init status --wait >/dev/null || true
if [[ ! -f /var/lib/k8s-prep-done ]]; then
  echo "Node preparation did not complete. See /var/log/k8s-node-prep.log" >&2
  exit 1
fi

if [[ -f /etc/kubernetes/kubelet.conf ]]; then
  echo "This node has already joined a cluster; nothing to do."
  exit 0
fi

kubeadm join "${ENDPOINT}" --token "${TOKEN}" --discovery-token-ca-cert-hash "${CA_HASH}"
