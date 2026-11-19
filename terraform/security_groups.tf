# Security groups: control plane and workers. Rules reference the groups themselves instead of IP
# ranges, so they keep working when nodes are replaced. There is no SSH rule and nothing is open
# to the internet. docs/security-groups.md explains every rule, in the lab and in production.
#
# Notes on how Terraform differs from the CLI scripts:
#   - Rules are separate aws_vpc_security_group_*_rule resources, not inline blocks. That avoids the
#     circular dependency of two groups that reference each other.
#   - Terraform removes the default allow-all egress rule of a new group, so egress is declared
#     explicitly below. Without it the nodes could not reach apt, registries or SSM.
#   - Rule descriptions allow only letters, digits and . _-:/()#,@[]+=&;{}!$* (no apostrophes).

resource "aws_security_group" "cp" {
  name        = "${var.cluster}-cp"
  description = "k8s control plane"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.cluster}-cp-sg"
  }
}

resource "aws_security_group" "worker" {
  name        = "${var.cluster}-worker"
  description = "k8s workers"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.cluster}-worker-sg"
  }
}

locals {
  # Control plane inbound. Key = stable name in the Terraform state; keep keys unchanged.
  cp_ingress = {
    api-from-workers = {
      protocol    = "tcp"
      from_port   = 6443
      to_port     = 6443
      source      = aws_security_group.worker.id
      description = "kube-apiserver from workers and pods (pod traffic leaves with the node IP via Calico natOutgoing)"
    }
    api-from-cp = {
      protocol    = "tcp"
      from_port   = 6443
      to_port     = 6443
      source      = aws_security_group.cp.id
      description = "kube-apiserver from other control plane nodes (no effect with one node)"
    }
    etcd-from-cp = {
      protocol    = "tcp"
      from_port   = 2379
      to_port     = 2380
      source      = aws_security_group.cp.id
      description = "etcd client and peer, control plane only"
    }
    kubelet-from-cp = {
      protocol    = "tcp"
      from_port   = 10250
      to_port     = 10250
      source      = aws_security_group.cp.id
      description = "kubelet API from control plane nodes"
    }
    kubelet-from-workers = {
      protocol    = "tcp"
      from_port   = 10250
      to_port     = 10250
      source      = aws_security_group.worker.id
      description = "kubelet API from metrics-server and Prometheus pods on workers"
    }
    vxlan-from-cp = {
      protocol    = "udp"
      from_port   = 4789
      to_port     = 4789
      source      = aws_security_group.cp.id
      description = "Calico VXLAN from control plane nodes"
    }
    vxlan-from-workers = {
      protocol    = "udp"
      from_port   = 4789
      to_port     = 4789
      source      = aws_security_group.worker.id
      description = "Calico VXLAN from workers"
    }
    typha-from-cp = {
      protocol    = "tcp"
      from_port   = 5473
      to_port     = 5473
      source      = aws_security_group.cp.id
      description = "Calico Typha from control plane nodes"
    }
    typha-from-workers = {
      protocol    = "tcp"
      from_port   = 5473
      to_port     = 5473
      source      = aws_security_group.worker.id
      description = "Calico Typha from workers"
    }
  }

  # Worker inbound.
  worker_ingress = {
    kubelet-from-cp = {
      protocol    = "tcp"
      from_port   = 10250
      to_port     = 10250
      source      = aws_security_group.cp.id
      description = "kubelet API from the API server (kubectl logs, exec, port-forward)"
    }
    kubelet-from-workers = {
      protocol    = "tcp"
      from_port   = 10250
      to_port     = 10250
      source      = aws_security_group.worker.id
      description = "kubelet API from metrics-server and Prometheus pods on other workers"
    }
    vxlan-from-cp = {
      protocol    = "udp"
      from_port   = 4789
      to_port     = 4789
      source      = aws_security_group.cp.id
      description = "Calico VXLAN from control plane nodes"
    }
    vxlan-from-workers = {
      protocol    = "udp"
      from_port   = 4789
      to_port     = 4789
      source      = aws_security_group.worker.id
      description = "Calico VXLAN from workers"
    }
    typha-from-cp = {
      protocol    = "tcp"
      from_port   = 5473
      to_port     = 5473
      source      = aws_security_group.cp.id
      description = "Calico Typha from control plane nodes"
    }
    typha-from-workers = {
      protocol    = "tcp"
      from_port   = 5473
      to_port     = 5473
      source      = aws_security_group.worker.id
      description = "Calico Typha from workers"
    }
  }
}

resource "aws_vpc_security_group_ingress_rule" "cp" {
  for_each = local.cp_ingress

  security_group_id            = aws_security_group.cp.id
  ip_protocol                  = each.value.protocol
  from_port                    = each.value.from_port
  to_port                      = each.value.to_port
  referenced_security_group_id = each.value.source
  description                  = each.value.description
}

resource "aws_vpc_security_group_ingress_rule" "worker" {
  for_each = local.worker_ingress

  security_group_id            = aws_security_group.worker.id
  ip_protocol                  = each.value.protocol
  from_port                    = each.value.from_port
  to_port                      = each.value.to_port
  referenced_security_group_id = each.value.source
  description                  = each.value.description
}

# NodePort range from inside the VPC only (used by the smoke test). In production replace the VPC
# CIDR with the load balancer's security group.
resource "aws_vpc_security_group_ingress_rule" "worker_nodeport" {
  security_group_id = aws_security_group.worker.id
  ip_protocol       = "tcp"
  from_port         = 30000
  to_port           = 32767
  cidr_ipv4         = var.vpc_cidr
  description       = "NodePort range from inside the VPC"
}

# Egress: allow all in the lab so apt, registries, GitHub and SSM work through the NAT gateway.
# Production restricts this (docs/security-groups.md, section 6).
resource "aws_vpc_security_group_egress_rule" "cp_all" {
  security_group_id = aws_security_group.cp.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "All outbound (lab)"
}

resource "aws_vpc_security_group_egress_rule" "worker_all" {
  security_group_id = aws_security_group.worker.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "All outbound (lab)"
}
