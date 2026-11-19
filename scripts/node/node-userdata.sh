#!/bin/bash
# EC2 user-data, identical on all three nodes. Runs once at first boot as root (cloud-init).
# 04-launch-instances.sh replaces __K8S_MINOR__ with the value from config.env.
#
# It prepares the node only. It does NOT run kubeadm init/join; those are separate steps
# (scripts 05 and 07) so each stage is visible and re-runnable.
# Progress log: /var/log/k8s-node-prep.log   Done marker: /var/lib/k8s-prep-done
set -euxo pipefail
exec > >(tee -a /var/log/k8s-node-prep.log) 2>&1

K8S_MINOR="__K8S_MINOR__"

# 1. Swap off (kubelet requirement); keep it off after reboot.
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

# 2. Kernel modules and sysctls required for pod networking.
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat >/etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# 3. containerd with the systemd cgroup driver (must match the kubelet).
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y apt-transport-https ca-certificates curl gpg containerd
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable containerd
systemctl restart containerd

# 4. kubeadm, kubelet, kubectl from the official pkgs.k8s.io repo; pinned to one minor and held
#    so an unattended apt upgrade can never move the cluster to a new Kubernetes version.
install -d -m 755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" |
  gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  >/etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet

touch /var/lib/k8s-prep-done
