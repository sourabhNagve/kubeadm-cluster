# One control plane and two workers in the private subnet.
#
# Hardening on every instance:
#   - no public IP, no key pair, no SSH (access is SSM only, see docs/ssm-guide.md)
#   - IMDSv2 required with hop limit 1, so pods cannot read the node's IAM credentials
#   - encrypted gp3 root volume

# Latest Ubuntu 24.04 LTS from Canonical (owner ID 099720109477), unless ami_id is set.
data "aws_ami" "ubuntu" {
  count = var.ami_id == "" ? 1 : 0

  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

locals {
  ami_id = var.ami_id != "" ? var.ami_id : data.aws_ami.ubuntu[0].id

  # Single source of truth shared with the AWS CLI path: scripts/node/node-userdata.sh.
  # file() is used instead of templatefile() because the script contains its own ${...} shell
  # variables; only the __K8S_MINOR__ placeholder is replaced.
  node_userdata = replace(
    file("${path.module}/../scripts/node/node-userdata.sh"),
    "__K8S_MINOR__",
    var.k8s_minor,
  )

  workers = toset(["worker1", "worker2"])
}

resource "aws_instance" "cp" {
  ami                         = local.ami_id
  instance_type               = var.cp_instance_type
  subnet_id                   = aws_subnet.private.id
  private_ip                  = var.cp_ip
  vpc_security_group_ids      = [aws_security_group.cp.id]
  iam_instance_profile        = aws_iam_instance_profile.node.name
  associate_public_ip_address = false
  user_data                   = local.node_userdata

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = var.root_volume_gb
    volume_type           = "gp3"
    encrypted             = true
    kms_key_id            = var.kms_key_id
    delete_on_termination = true

    tags = {
      Name    = "${var.cluster}-cp"
      project = var.cluster
    }
  }

  tags = {
    Name                                   = "${var.cluster}-cp"
    "kubernetes.io/cluster/${var.cluster}" = "owned"
  }

  # The user-data script downloads packages at first boot, so wait until the private subnet
  # actually has a route to the NAT gateway and the node may send traffic out.
  depends_on = [
    aws_route.private_nat,
    aws_route_table_association.private,
    aws_vpc_security_group_egress_rule.cp_all,
    aws_iam_role_policy_attachment.node_ssm,
  ]

  lifecycle {
    # A new Ubuntu AMI or an edited user-data script must never replace a running cluster node.
    # To roll nodes onto a new image, replace them deliberately:
    #   terraform apply -replace=aws_instance.cp   (see docs/operations.md before doing this)
    ignore_changes = [ami, user_data]
  }
}

resource "aws_instance" "worker" {
  for_each = local.workers

  ami                         = local.ami_id
  instance_type               = var.worker_instance_type
  subnet_id                   = aws_subnet.private.id
  vpc_security_group_ids      = [aws_security_group.worker.id]
  iam_instance_profile        = aws_iam_instance_profile.node.name
  associate_public_ip_address = false
  user_data                   = local.node_userdata

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = var.root_volume_gb
    volume_type           = "gp3"
    encrypted             = true
    kms_key_id            = var.kms_key_id
    delete_on_termination = true

    tags = {
      Name    = "${var.cluster}-${each.key}"
      project = var.cluster
    }
  }

  tags = {
    Name                                   = "${var.cluster}-${each.key}"
    "kubernetes.io/cluster/${var.cluster}" = "owned"
  }

  depends_on = [
    aws_route.private_nat,
    aws_route_table_association.private,
    aws_vpc_security_group_egress_rule.worker_all,
    aws_iam_role_policy_attachment.node_ssm,
  ]

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}
