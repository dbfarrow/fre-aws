locals {
  # Subnet selection based on network_mode
  use_private_subnet = var.network_mode != "public"

  # When true, skip VPC/NAT/endpoint creation and use existing IDs directly
  using_existing_vpc = var.existing_vpc_id != ""

  # Active VPC and subnet — either the created ones or the provided existing ones
  vpc_id = local.using_existing_vpc ? var.existing_vpc_id : module.vpc[0].vpc_id

  subnet_id = local.using_existing_vpc ? var.existing_subnet_id : (
    local.use_private_subnet ? module.vpc[0].private_subnets[0] : module.vpc[0].public_subnets[0]
  )

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

# Validate existing VPC/subnet at plan time — fails fast if IDs don't exist in the region
data "aws_vpc" "existing" {
  count = local.using_existing_vpc ? 1 : 0
  id    = var.existing_vpc_id
}

data "aws_subnet" "existing" {
  count = local.using_existing_vpc ? 1 : 0
  id    = var.existing_subnet_id
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  count = local.using_existing_vpc ? 0 : 1

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
  count = var.network_mode == "private_endpoints" && !local.using_existing_vpc ? 1 : 0

  vpc_id            = module.vpc[0].vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type = "Interface"
  subnet_ids        = module.vpc[0].private_subnets

  security_group_ids  = [module.ssm_endpoint_sg[0].security_group_id]
  private_dns_enabled = true

  tags = merge(local.owner_tags, {
    ProjectName = var.project_name
  })
}

resource "aws_vpc_endpoint" "ec2messages" {
  count = var.network_mode == "private_endpoints" && !local.using_existing_vpc ? 1 : 0

  vpc_id            = module.vpc[0].vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.ec2messages"
  vpc_endpoint_type = "Interface"
  subnet_ids        = module.vpc[0].private_subnets

  security_group_ids  = [module.ssm_endpoint_sg[0].security_group_id]
  private_dns_enabled = true

  tags = merge(local.owner_tags, {
    ProjectName = var.project_name
  })
}

resource "aws_vpc_endpoint" "ssmmessages" {
  count = var.network_mode == "private_endpoints" && !local.using_existing_vpc ? 1 : 0

  vpc_id            = module.vpc[0].vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.ssmmessages"
  vpc_endpoint_type = "Interface"
  subnet_ids        = module.vpc[0].private_subnets

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

  count = var.network_mode == "private_endpoints" && !local.using_existing_vpc ? 1 : 0

  name        = "${var.project_name}-ssm-endpoint-sg"
  description = "Allow HTTPS from VPC for SSM endpoints"
  vpc_id      = module.vpc[0].vpc_id

  ingress_with_cidr_blocks = [
    {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = module.vpc[0].vpc_cidr_block
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
  vpc_id      = local.vpc_id

  # Zero Trust: no ingress rules
  ingress_rules = []

  # Allow all outbound (SSM, package installs, Claude API)
  egress_rules = ["all-all"]

  tags = merge(local.owner_tags, {
    ProjectName = var.project_name
  })
}
