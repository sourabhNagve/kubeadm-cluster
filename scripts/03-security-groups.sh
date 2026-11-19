#!/usr/bin/env bash
# Phase 1, step 3: security groups.
#
# Two groups: control plane (CP_SG) and workers (WK_SG). Rules reference the groups themselves
# instead of IP ranges, so they keep working when nodes are replaced. There is no SSH rule and
# no rule open to the internet. See docs/security-groups.md for the reasoning behind each line.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require VPC_ID

log "Create security groups"
if [[ -z "${CP_SG:-}" ]]; then
  save CP_SG "$(aws ec2 create-security-group --group-name "${CLUSTER}-cp" \
    --description "k8s control plane" --vpc-id "$VPC_ID" \
    --tag-specifications "$(tag_spec security-group cp-sg)" \
    --query GroupId --output text)"
fi
if [[ -z "${WK_SG:-}" ]]; then
  save WK_SG "$(aws ec2 create-security-group --group-name "${CLUSTER}-worker" \
    --description "k8s workers" --vpc-id "$VPC_ID" \
    --tag-specifications "$(tag_spec security-group worker-sg)" \
    --query GroupId --output text)"
fi
info "CP_SG=$CP_SG"
info "WK_SG=$WK_SG"

# Rule format: allow_sg <target SG> <protocol> <from port> <to port> <source SG>

log "Control plane SG: kube-apiserver (tcp 6443)"
# Workers: kubelet, kube-proxy, Calico and every pod that talks to the API server. Pod traffic
# leaves the node with the node's IP (Calico natOutgoing), so the source is the worker SG.
allow_sg "$CP_SG" tcp 6443 6443 "$WK_SG"
# Other control-plane nodes (no effect with one node; needed once you add more).
allow_sg "$CP_SG" tcp 6443 6443 "$CP_SG"

log "Control plane SG: etcd (tcp 2379-2380), control plane only"
allow_sg "$CP_SG" tcp 2379 2380 "$CP_SG"

log "Control plane SG: kubelet API (tcp 10250)"
allow_sg "$CP_SG" tcp 10250 10250 "$CP_SG"
# metrics-server and Prometheus run as pods on workers and scrape every kubelet.
allow_sg "$CP_SG" tcp 10250 10250 "$WK_SG"

log "Control plane SG: Calico VXLAN (udp 4789) and Typha (tcp 5473)"
allow_sg "$CP_SG" udp 4789 4789 "$CP_SG"
allow_sg "$CP_SG" udp 4789 4789 "$WK_SG"
allow_sg "$CP_SG" tcp 5473 5473 "$CP_SG"
allow_sg "$CP_SG" tcp 5473 5473 "$WK_SG"

log "Worker SG: kubelet API (tcp 10250)"
# The API server uses it for kubectl logs / exec / port-forward.
allow_sg "$WK_SG" tcp 10250 10250 "$CP_SG"
# Scrapers (metrics-server, Prometheus) running on other workers.
allow_sg "$WK_SG" tcp 10250 10250 "$WK_SG"

log "Worker SG: Calico VXLAN (udp 4789) and Typha (tcp 5473)"
allow_sg "$WK_SG" udp 4789 4789 "$CP_SG"
allow_sg "$WK_SG" udp 4789 4789 "$WK_SG"
allow_sg "$WK_SG" tcp 5473 5473 "$CP_SG"
allow_sg "$WK_SG" tcp 5473 5473 "$WK_SG"

log "Worker SG: NodePort range (tcp 30000-32767) from inside the VPC only"
# Used by the smoke test. In production, replace the VPC CIDR with your load balancer's SG.
allow_cidr "$WK_SG" tcp 30000 32767 "$VPC_CIDR"

log "Summary"
aws ec2 describe-security-groups --group-ids "$CP_SG" "$WK_SG" \
  --query 'SecurityGroups[].[GroupName,GroupId,length(IpPermissions)]' --output table

log "Security groups ready. Next: ./scripts/04-launch-instances.sh"
