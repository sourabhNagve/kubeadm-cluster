provider "aws" {
  region = var.aws_region

  # Applied to every resource that supports tags. The SSM operator policy in iam/ matches on the
  # "project" tag, so keep it.
  default_tags {
    tags = {
      project    = var.cluster
      managed-by = "terraform"
    }
  }
}
