#!/usr/bin/env bash
# Phase 1, step 4: launch 1 control plane + 2 workers in the private subnet.
#
# Hardening applied to every instance:
#   - no public IP, no key pair, no SSH (access is SSM only)
#   - IMDSv2 required, hop limit 1 (pods cannot reach the node's IAM credentials)
#   - encrypted gp3 root volume
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require PRIV_SUBNET
require CP_SG
require WK_SG

USERDATA_TEMPLATE="$ROOT_DIR/scripts/node/node-userdata.sh"
USERDATA_RENDERED="$ROOT_DIR/.state/node-userdata.sh"

log "Render user-data (Kubernetes $K8S_MINOR)"
sed "s/__K8S_MINOR__/${K8S_MINOR}/" "$USERDATA_TEMPLATE" >"$USERDATA_RENDERED"

log "Look up the latest Ubuntu 24.04 LTS AMI (Canonical, via public SSM parameter)"
if [[ -z "${AMI:-}" ]]; then
  save AMI "$(aws ssm get-parameter \
    --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
    --query Parameter.Value --output text)"
fi
info "AMI=$AMI"

# launch NAME SECURITY_GROUP INSTANCE_TYPE [extra run-instances args...]
launch() {
  local name=$1 sg=$2 type=$3
  shift 3
  aws ec2 run-instances \
    --image-id "$AMI" \
    --instance-type "$type" \
    --subnet-id "$PRIV_SUBNET" \
    --security-group-ids "$sg" \
    --iam-instance-profile "Name=${IAM_PROFILE_NAME:-${CLUSTER}-node-profile}" \
    --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=${ROOT_VOLUME_GB},VolumeType=gp3,Encrypted=true,DeleteOnTermination=true}" \
    --user-data "file://${USERDATA_RENDERED}" \
    --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=${CLUSTER}-${name}},{Key=project,Value=${CLUSTER}},{Key=kubernetes.io/cluster/${CLUSTER},Value=owned}]" \
    "ResourceType=volume,Tags=[{Key=Name,Value=${CLUSTER}-${name}},{Key=project,Value=${CLUSTER}}]" \
    "$@" \
    --query 'Instances[0].InstanceId' --output text
}

# shellcheck disable=SC2153  # CP_IP comes from config.env
log "Launch control plane ($INSTANCE_TYPE_CP, fixed IP $CP_IP)"
if [[ -z "${CP_ID:-}" ]]; then
  save CP_ID "$(launch cp "$CP_SG" "$INSTANCE_TYPE_CP" --private-ip-address "$CP_IP")"
fi
info "CP_ID=$CP_ID"

log "Launch worker 1 ($INSTANCE_TYPE_WORKER)"
if [[ -z "${W1_ID:-}" ]]; then
  save W1_ID "$(launch worker1 "$WK_SG" "$INSTANCE_TYPE_WORKER")"
fi
info "W1_ID=$W1_ID"

log "Launch worker 2 ($INSTANCE_TYPE_WORKER)"
if [[ -z "${W2_ID:-}" ]]; then
  save W2_ID "$(launch worker2 "$WK_SG" "$INSTANCE_TYPE_WORKER")"
fi
info "W2_ID=$W2_ID"

log "Waiting for the instances to reach the running state"
aws ec2 wait instance-running --instance-ids "$CP_ID" "$W1_ID" "$W2_ID"

cat <<EOF

Instances are running. Give them 3-5 minutes: the SSM agent has to register and the
user-data script has to install containerd and the Kubernetes packages.

Check registration (all three must show Online):
    ./scripts/ssm.sh status

Then continue with the cluster phase:
    ./scripts/05-init-control-plane.sh
EOF
