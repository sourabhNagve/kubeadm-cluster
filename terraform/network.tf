# Custom VPC: one public subnet (NAT gateway only) and one private subnet (all nodes).
# See docs/architecture.md for the diagram.

locals {
  az = "${var.aws_region}${var.az_suffix}"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.cluster}-vpc"
  }
}

# Lock down the VPC's default security group (CIS AWS Foundations 5.4): no rules at all, so
# nothing can accidentally rely on it. Our own groups are in security_groups.tf.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.cluster}-default-sg-unused"
  }
}

# ---- Subnets ----

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = local.az
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.cluster}-subnet-public"
  }
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnet_cidr
  availability_zone       = local.az
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.cluster}-subnet-private"
  }
}

# ---- Internet access ----

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.cluster}-igw"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.cluster}-nat-eip"
  }

  depends_on = [aws_internet_gateway.main]
}

# Outbound-only internet for the private subnet (apt, container registries, GitHub, SSM).
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = {
    Name = "${var.cluster}-nat"
  }

  depends_on = [aws_internet_gateway.main]
}

# ---- Route tables (explicit; the VPC main route table stays empty) ----

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.cluster}-public-rt"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.cluster}-private-rt"
  }
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}
