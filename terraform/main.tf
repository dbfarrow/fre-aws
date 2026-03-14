locals {
  # Subnet selection based on network_mode
  use_private_subnet = var.network_mode != "public"

  # Tag all resources with owner if provided
  owner_tags = var.owner_email != "" ? { Owner = var.owner_email } : {}
}

# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
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
}

resource "aws_vpc_endpoint" "ec2messages" {
  count = var.network_mode == "private_endpoints" ? 1 : 0

  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.ec2messages"
  vpc_endpoint_type = "Interface"
  subnet_ids        = module.vpc.private_subnets

  security_group_ids  = [module.ssm_endpoint_sg[0].security_group_id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ssmmessages" {
  count = var.network_mode == "private_endpoints" ? 1 : 0

  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.ssmmessages"
  vpc_endpoint_type = "Interface"
  subnet_ids        = module.vpc.private_subnets

  security_group_ids  = [module.ssm_endpoint_sg[0].security_group_id]
  private_dns_enabled = true
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
}

# ---------------------------------------------------------------------------
# Per-user IAM roles and EC2 instances
# ---------------------------------------------------------------------------

resource "aws_iam_role" "user_ec2" {
  for_each    = var.users
  name        = "${var.project_name}-${each.key}-ec2-role"
  description = "EC2 instance role for ${each.key}: SSM access only"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  for_each   = var.users
  role       = aws_iam_role.user_ec2[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "user_ec2" {
  for_each = var.users
  name     = "${var.project_name}-${each.key}-ec2-profile"
  role     = aws_iam_role.user_ec2[each.key].name
}

module "user_ec2" {
  for_each = var.users
  source   = "terraform-aws-modules/ec2-instance/aws"
  version  = "~> 5.0"

  name = "${var.project_name}-${each.key}-dev"

  ami           = data.aws_ami.amazon_linux_2023.id
  instance_type = var.instance_type

  # Network placement
  subnet_id                   = local.use_private_subnet ? module.vpc.private_subnets[0] : module.vpc.public_subnets[0]
  associate_public_ip_address = !local.use_private_subnet
  vpc_security_group_ids      = [module.ec2_sg.security_group_id]

  # IAM
  iam_instance_profile = aws_iam_instance_profile.user_ec2[each.key].name

  # Spot instance — uses dedicated module variables (not instance_market_options)
  create_spot_instance                = var.use_spot
  spot_instance_interruption_behavior = "stop" # preserve EBS data on interruption

  # IMDSv2 (Zero Trust: prevents SSRF-based credential theft)
  metadata_options = {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  # Encrypted root volume
  root_block_device = [
    {
      volume_size           = var.ebs_volume_size_gb
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = module.kms.key_arn
      delete_on_termination = true
    }
  ]

  # Provisioning variables are injected directly — no SSM parameter reads at boot.
  # SSH key and git identity come from users.tfvars; session_start.sh from scripts/.
  # To update session_start.sh on a running instance: ./admin.sh refresh <username>
  user_data = join("\n", [
    "#!/usr/bin/env bash",
    "# EC2 user data for ${var.project_name} / ${each.key}",
    "set -euo pipefail",
    "exec > >(tee /var/log/user-data.log | logger -t user-data) 2>&1",
    "echo '=== Claude Code environment bootstrap starting ==='",
    "",
    "# Provisioning variables injected by Terraform at provision time",
    "DEV_USERNAME='${each.key}'",
    "REGION='${var.aws_region}'",
    "PROJECT_NAME='${var.project_name}'",
    "SSH_PUBLIC_KEY='${each.value.ssh_public_key}'",
    "GIT_USER_NAME='${each.value.git_user_name}'",
    "GIT_USER_EMAIL='${each.value.git_user_email}'",
    "",
    file("${path.module}/user_data_main.sh"),
    "",
    "# ---------------------------------------------------------------------------",
    "# Session launcher — injected from scripts/session_start.sh at provision time",
    "# ---------------------------------------------------------------------------",
    "cat > /home/developer/session_start.sh << 'SESSION_LAUNCHER'",
    file("${path.module}/../scripts/session_start.sh"),
    "SESSION_LAUNCHER",
    "chmod +x /home/developer/session_start.sh",
    "chown developer:developer /home/developer/session_start.sh",
    file("${path.module}/user_data_tail.sh"),
  ])
  user_data_replace_on_change = false

  tags = merge(local.owner_tags, {
    ProjectName = var.project_name
    Username    = each.key
  })
}
