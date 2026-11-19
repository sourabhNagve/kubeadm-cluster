#!/usr/bin/env bash
# Phase 1, step 1: custom VPC, public + private subnet, IGW, NAT gateway, route tables.
# Safe to re-run: resources already recorded in .state/cluster.env are skipped.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log "VPC ($VPC_CIDR) in $AWS_REGION / $AZ"
if [[ -z "${VPC_ID:-}" ]]; then
  save VPC_ID "$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
    --tag-specifications "$(tag_spec vpc vpc)" --query Vpc.VpcId --output text)"
  aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
  aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'
fi
info "VPC_ID=$VPC_ID"

log "Subnets"
if [[ -z "${PUB_SUBNET:-}" ]]; then
  save PUB_SUBNET "$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PUB_CIDR" \
    --availability-zone "$AZ" --tag-specifications "$(tag_spec subnet public)" \
    --query Subnet.SubnetId --output text)"
fi
if [[ -z "${PRIV_SUBNET:-}" ]]; then
  save PRIV_SUBNET "$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PRIV_CIDR" \
    --availability-zone "$AZ" --tag-specifications "$(tag_spec subnet private)" \
    --query Subnet.SubnetId --output text)"
fi
info "public  $PUB_SUBNET ($PUB_CIDR)"
info "private $PRIV_SUBNET ($PRIV_CIDR)"

log "Internet gateway (public subnet only)"
if [[ -z "${IGW_ID:-}" ]]; then
  save IGW_ID "$(aws ec2 create-internet-gateway \
    --tag-specifications "$(tag_spec internet-gateway igw)" \
    --query InternetGateway.InternetGatewayId --output text)"
  aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
fi
info "IGW_ID=$IGW_ID"

log "NAT gateway (outbound-only internet for the private subnet)"
if [[ -z "${EIP_ALLOC:-}" ]]; then
  save EIP_ALLOC "$(aws ec2 allocate-address --domain vpc \
    --tag-specifications "$(tag_spec elastic-ip nat-eip)" \
    --query AllocationId --output text)"
fi
if [[ -z "${NAT_ID:-}" ]]; then
  save NAT_ID "$(aws ec2 create-nat-gateway --subnet-id "$PUB_SUBNET" --allocation-id "$EIP_ALLOC" \
    --tag-specifications "$(tag_spec natgateway nat)" \
    --query NatGateway.NatGatewayId --output text)"
fi
info "waiting for $NAT_ID to become available (1-2 minutes)"
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_ID"

log "Route tables (explicit; the VPC main route table is left empty)"
if [[ -z "${PUB_RT:-}" ]]; then
  save PUB_RT "$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
    --tag-specifications "$(tag_spec route-table public-rt)" \
    --query RouteTable.RouteTableId --output text)"
  aws ec2 create-route --route-table-id "$PUB_RT" --destination-cidr-block 0.0.0.0/0 \
    --gateway-id "$IGW_ID" >/dev/null
  aws ec2 associate-route-table --route-table-id "$PUB_RT" --subnet-id "$PUB_SUBNET" >/dev/null
fi
if [[ -z "${PRIV_RT:-}" ]]; then
  save PRIV_RT "$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
    --tag-specifications "$(tag_spec route-table private-rt)" \
    --query RouteTable.RouteTableId --output text)"
  aws ec2 create-route --route-table-id "$PRIV_RT" --destination-cidr-block 0.0.0.0/0 \
    --nat-gateway-id "$NAT_ID" >/dev/null
  aws ec2 associate-route-table --route-table-id "$PRIV_RT" --subnet-id "$PRIV_SUBNET" >/dev/null
fi
info "public-rt  $PUB_RT  -> 0.0.0.0/0 via $IGW_ID"
info "private-rt $PRIV_RT -> 0.0.0.0/0 via $NAT_ID"

log "Network ready. Next: ./scripts/02-iam.sh"
