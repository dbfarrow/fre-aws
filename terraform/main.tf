locals {
  # Subnet selection based on network_mode
  use_private_subnet = var.network_mode != "public"

  # Tag all resources with owner if provided
  owner_tags = var.owner_email != "" ? { Owner = var.owner_email } : {}
}

# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

# ---------------------------------------------------------------------------
# KMS key — used for EBS and S3 encryption
# ---------------------------------------------------------------------------

module "kms" {
  source  = "terraform-aws-modules/kms/aws"
  version = "~> 3.0"

  description             = "${var.project_name} encryption key"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  aliases = ["${var.project_name}/main"]

  # Allow any IAM principal in this account to use the key via EC2/EBS.
  # This is the AWS-recommended pattern for CMK-encrypted EBS volumes:
  # the ViaService condition ensures the key can only be used through EC2,
  # and GrantIsForAWSResource ensures CreateGrant is only used for AWS services.
  # Without this, only principals with explicit kms:CreateGrant (e.g. AdminAccess)
  # can start instances with encrypted EBS — {project}-developer-access would fail.
  key_statements = [
    {
      sid = "AllowEBSEncryption"
      effect = "Allow"
      principals = [{
        type        = "AWS"
        identifiers = ["*"]
      }]
      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:DescribeKey",
      ]
      resources = ["*"]
      conditions = [
        {
          test     = "StringEquals"
          variable = "kms:CallerAccount"
          values   = [data.aws_caller_identity.current.account_id]
        },
        {
          test     = "StringEquals"
          variable = "kms:ViaService"
          values   = ["ec2.${var.aws_region}.amazonaws.com"]
        },
      ]
    },
    {
      sid = "AllowEBSGrants"
      effect = "Allow"
      principals = [{
        type        = "AWS"
        identifiers = ["*"]
      }]
      actions = [
        "kms:CreateGrant",
        "kms:ListGrants",
        "kms:RevokeGrant",
      ]
      resources = ["*"]
      conditions = [
        {
          test     = "StringEquals"
          variable = "kms:CallerAccount"
          values   = [data.aws_caller_identity.current.account_id]
        },
        {
          test     = "StringEquals"
          variable = "kms:ViaService"
          values   = ["ec2.${var.aws_region}.amazonaws.com"]
        },
        {
          test     = "Bool"
          variable = "kms:GrantIsForAWSResource"
          values   = ["true"]
        },
      ]
    },
  ]
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.project_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  # NAT Gateway: only needed for private_nat mode
  enable_nat_gateway     = var.network_mode == "private_nat"
  single_nat_gateway     = true # one NAT gateway is enough; saves ~$33/month vs one-per-AZ
  one_nat_gateway_per_az = false

  # VPC endpoints for SSM: only needed for private_endpoints mode
  enable_vpn_gateway = false
}

# VPC endpoints for SSM (private_endpoints mode only)
resource "aws_vpc_endpoint" "ssm" {
  count = var.network_mode == "private_endpoints" ? 1 : 0

  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type = "Interface"
  subnet_ids        = module.vpc.private_subnets

  security_group_ids  = [module.ssm_endpoint_sg[0].security_group_id]
  private_dns_enabled = true

  tags = merge(local.owner_tags, {
    ProjectName = var.project_name
  })
}

resource "aws_vpc_endpoint" "ec2messages" {
  count = var.network_mode == "private_endpoints" ? 1 : 0

  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.ec2messages"
  vpc_endpoint_type = "Interface"
  subnet_ids        = module.vpc.private_subnets

  security_group_ids  = [module.ssm_endpoint_sg[0].security_group_id]
  private_dns_enabled = true

  tags = merge(local.owner_tags, {
    ProjectName = var.project_name
  })
}

resource "aws_vpc_endpoint" "ssmmessages" {
  count = var.network_mode == "private_endpoints" ? 1 : 0

  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.ssmmessages"
  vpc_endpoint_type = "Interface"
  subnet_ids        = module.vpc.private_subnets

  security_group_ids  = [module.ssm_endpoint_sg[0].security_group_id]
  private_dns_enabled = true

  tags = merge(local.owner_tags, {
    ProjectName = var.project_name
  })
}

# Security group for VPC endpoints (allows HTTPS from within VPC)
module "ssm_endpoint_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  count = var.network_mode == "private_endpoints" ? 1 : 0

  name        = "${var.project_name}-ssm-endpoint-sg"
  description = "Allow HTTPS from VPC for SSM endpoints"
  vpc_id      = module.vpc.vpc_id

  ingress_with_cidr_blocks = [
    {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = module.vpc.vpc_cidr_block
      description = "HTTPS from VPC"
    }
  ]

  egress_rules = ["all-all"]

  tags = merge(local.owner_tags, {
    ProjectName = var.project_name
  })
}

# ---------------------------------------------------------------------------
# Security Group for EC2 — no ingress, all egress (shared across all users)
# ---------------------------------------------------------------------------

module "ec2_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "${var.project_name}-ec2-sg"
  description = "EC2 dev instance: no inbound, SSM outbound only"
  vpc_id      = module.vpc.vpc_id

  # Zero Trust: no ingress rules
  ingress_rules = []

  # Allow all outbound (SSM, package installs, Claude API)
  egress_rules = ["all-all"]

  tags = merge(local.owner_tags, {
    ProjectName = var.project_name
  })
}
