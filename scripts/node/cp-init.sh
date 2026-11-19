#!/usr/bin/env bash
# Runs ON the control-plane node, as root, through SSM (scripts/05-init-control-plane.sh).
# $1 = base64 of the rendered kubeadm config.
set -euo pipefail

KUBEADM_CONFIG_B64="${1:?kubeadm config (base64) is required}"

echo "Waiting for node preparation (cloud-init user-data) to finish..."
cloud-init status --wait >/dev/null || true
if [[ ! -f /var/lib/k8s-prep-done ]]; then
  echo "Node preparation did not complete. See /var/log/k8s-node-prep.log" >&2
  exit 1
fi

if [[ -f /etc/kubernetes/admin.conf ]]; then
  echo "Control plane is already initialised; nothing to do."
  exit 0
fi

# Encryption at rest for Secrets. The key is generated here and never leaves the node.
install -d -m 700 /etc/kubernetes/enc
if [[ ! -f /etc/kubernetes/enc/enc.yaml ]]; then
  (
    umask 077
    cat >/etc/kubernetes/enc/enc.yaml <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources: ["secrets"]
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: $(head -c 32 /dev/urandom | base64)
      - identity: {}
EOF
  )
fi

echo "${KUBEADM_CONFIG_B64}" | base64 -d >/root/kubeadm-config.yaml
kubeadm init --config /root/kubeadm-config.yaml

# Convenience for interactive sessions: after `sudo -i`, kubectl just works.
install -d -m 700 /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config

echo
echo "Control plane initialised:"
kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes
echo "(NotReady is expected until the CNI is installed: ./scripts/06-install-cni.sh)"
