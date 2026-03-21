terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  # No profile here — credentials are exported as AWS_ACCESS_KEY_ID /
  # AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN by up.sh before Terraform runs.

  default_tags {
    tags = {
      Project    = var.project_name
      ManagedBy  = "terraform"
      Repository = "fre-aws"
    }
  }
}
