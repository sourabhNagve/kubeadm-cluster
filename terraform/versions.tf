terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Local state is fine for a lab. For anything shared, use a remote backend:
  # copy backend.tf.example to backend.tf (see docs/terraform.md).
}
