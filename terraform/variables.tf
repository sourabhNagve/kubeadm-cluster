variable "aws_region" {
  description = "AWS region for every resource."
  type        = string
  default     = "ap-south-1"
}

variable "az_suffix" {
  description = "Availability zone letter appended to the region, for example \"a\" gives us-east-1a. The lab uses a single AZ."
  type        = string
  default     = "a"
}

variable "cluster" {
  description = "Prefix for every resource name and the value of the \"project\" tag. Lowercase letters, digits and hyphens."
  type        = string
  default     = "kubeadm-blog-app"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.cluster))
    error_message = "cluster must start with a letter and contain only lowercase letters, digits and hyphens (2-31 characters)."
  }
}

# ---- Network ----

variable "vpc_cidr" {
  description = "CIDR of the dedicated VPC (never the default VPC)."
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  description = "Public subnet: holds only the NAT gateway."
  type        = string
  default     = "10.20.0.0/24"
}

variable "private_subnet_cidr" {
  description = "Private subnet: all three nodes."
  type        = string
  default     = "10.20.10.0/24"
}

variable "cp_ip" {
  description = "Fixed private IP of the control plane. It must be inside private_subnet_cidr and not one of the first four addresses (AWS reserves them). It becomes the Kubernetes API endpoint."
  type        = string
  default     = "10.20.10.10"
}

# ---- Instances ----

variable "cp_instance_type" {
  description = "Instance type of the control plane (kubeadm needs at least 2 vCPU and 2 GB)."
  type        = string
  default     = "c7i-flex.large"
}

variable "worker_instance_type" {
  description = "Instance type of the two workers."
  type        = string
  default     = "c7i-flex.large"
}

variable "root_volume_gb" {
  description = "Size of the encrypted gp3 root volume of every node."
  type        = number
  default     = 10
}

variable "kms_key_id" {
  description = "Optional customer-managed KMS key (ARN or ID) for the EBS volumes. null uses the AWS-managed aws/ebs key."
  type        = string
  default     = null
}

variable "ami_id" {
  description = "Pin a specific AMI. Empty (default) resolves the latest Ubuntu 24.04 LTS from Canonical's public SSM parameter at plan time; existing nodes ignore later AMI changes (see instances.tf)."
  type        = string
  default     = ""
}

# ---- Kubernetes ----

variable "k8s_minor" {
  description = "Kubernetes minor version for the pkgs.k8s.io apt repository, installed by the node user-data."
  type        = string
  default     = "v1.36"

  validation {
    condition     = can(regex("^v1\\.[0-9]+$", var.k8s_minor))
    error_message = "k8s_minor must look like v1.36."
  }
}

