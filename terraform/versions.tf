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
  # Setting profile alongside those env vars causes AWS provider v5 to prefer
  # the profile and ignore the exported creds, breaking SSO-based auth.

  default_tags {
    tags = {
      Project    = var.project_name
      ManagedBy  = "terraform"
      Repository = "fre-aws"
    }
  }
}
