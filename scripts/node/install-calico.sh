#!/usr/bin/env bash
# Runs ON the control-plane node, as root, through SSM (scripts/06-install-cni.sh).
# $1 = base64 of the rendered Installation manifest (k8s/calico-installation.yaml)
# $2 = Calico version, e.g. v3.31.0 (optional; empty = latest GitHub release)
set -euo pipefail

export KUBECONFIG=/etc/kubernetes/admin.conf
INSTALLATION_B64="${1:?Installation manifest (base64) is required}"
CALICO_VERSION="${2:-}"

if [[ -z "$CALICO_VERSION" ]]; then
  CALICO_VERSION=$(curl -fsSL https://api.github.com/repos/projectcalico/calico/releases/latest |
   awk -F'"' '/"tag_name":/ {print $4; exit}') || true
fi
if [[ -z "$CALICO_VERSION" ]]; then
  echo "Could not determine the latest Calico release (GitHub API rate limit?)." >&2
  echo "Set CALICO_VERSION in config.env (for example v3.31.0) and run again." >&2
  exit 1
fi
echo "Installing Calico ${CALICO_VERSION}"

# Server-side apply is what the Calico docs recommend: the operator CRDs are too large for
# client-side apply, and it makes this step safe to re-run.
kubectl apply --server-side -f \
  "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"

# The Installation resource can only be created once its CRD is registered.
kubectl wait --for=condition=Established crd/installations.operator.tigera.io --timeout=120s

echo "${INSTALLATION_B64}" | base64 -d | kubectl apply -f -

echo "Waiting for the control-plane node to become Ready (image pulls take a few minutes)..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s

kubectl get nodes
kubectl get pods -A
