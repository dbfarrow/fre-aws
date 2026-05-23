locals {
  # Tag all resources with owner if provided
  owner_tags = var.owner_email != "" ? { Owner = var.owner_email } : {}

  # Use the pinned AMI if provided (existing instance); fall back to latest for new instances.
  # ami_id is populated by up.sh from the running instance's current AMI, so routine
  # `up` runs never replace an existing instance just because Amazon published a new AMI.
  resolved_ami = var.ami_id != "" ? var.ami_id : data.aws_ami.amazon_linux_2023.id

  # Bash snippet to append admin SSH keys to authorized_keys (empty string if none configured)
  admin_keys_block = length(var.admin_ssh_keys) == 0 ? "" : join("\n", concat(
    [
      "",
      "# ---------------------------------------------------------------------------",
      "# Admin SSH keys (appended at provision time for admin instance access)",
      "# ---------------------------------------------------------------------------",
      "mkdir -p /home/developer/.ssh",
      "chmod 700 /home/developer/.ssh",
    ],
    [for k in var.admin_ssh_keys : "echo '${k}' >> /home/developer/.ssh/authorized_keys"],
    [
      "chmod 600 /home/developer/.ssh/authorized_keys",
      "chown -R developer:developer /home/developer/.ssh",
      "echo 'Admin SSH key(s) appended to authorized_keys.'",
    ]
  ))
}

# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ---------------------------------------------------------------------------
# IAM role and instance profile
# ---------------------------------------------------------------------------

resource "aws_iam_role" "user_ec2" {
  name        = "${var.project_name}-${var.username}-ec2-role"
  description = "EC2 instance role for ${var.username}: SSM access only"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.owner_tags, {
    ProjectName = var.project_name
    Username    = var.username
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.user_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Allow the instance to stop itself via the EC2 API.
# Scoped to instances tagged with this project and this user so the instance
# cannot stop other users' instances. The autoshutdown timer uses this instead
# of "sudo shutdown -h now" so that AWS records "User initiated (timestamp)" in
# StateTransitionReason, making the stop time visible in list/stat output.
resource "aws_iam_role_policy" "ec2_self_stop" {
  name = "self-stop"
  role = aws_iam_role.user_ec2.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "ec2:StopInstances"
      Resource = "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"
      Condition = {
        StringEquals = {
          "aws:ResourceTag/ProjectName" = var.project_name
          "aws:ResourceTag/Username"    = var.username
        }
      }
    }]
  })
}

# Allow the instance to read and write its own LiteLLM API key in Secrets Manager.
# Always present — harmless when LiteLLM is not configured (grants access to a secret
# that doesn't exist). Scoped to this user's key path only.
resource "aws_iam_role_policy" "litellm_secret" {
  name = "litellm-secret-access"
  role = aws_iam_role.user_ec2.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "LiteLLMKeyAccess"
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:CreateSecret",
        "secretsmanager:PutSecretValue"
      ]
      Resource = "arn:aws:secretsmanager:*:${data.aws_caller_identity.current.account_id}:secret:${var.project_name}/${var.username}/litellm-key-*"
    }]
  })
}

resource "aws_iam_instance_profile" "user_ec2" {
  name = "${var.project_name}-${var.username}-ec2-profile"
  role = aws_iam_role.user_ec2.name

  tags = merge(local.owner_tags, {
    ProjectName = var.project_name
    Username    = var.username
  })
}

# ---------------------------------------------------------------------------
# EC2 instance
# ---------------------------------------------------------------------------

module "user_ec2" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 5.0"

  name = "${var.project_name}-${var.username}-dev"

  ami           = local.resolved_ami
  instance_type = var.instance_type

  # Network placement — pre-selected by base module based on network_mode
  subnet_id                   = var.subnet_id
  associate_public_ip_address = var.associate_public_ip
  vpc_security_group_ids      = [var.security_group_id]

  # IAM
  iam_instance_profile = aws_iam_instance_profile.user_ec2.name

  # Spot instance — uses dedicated module variables (not instance_market_options)
  create_spot_instance                = var.use_spot
  spot_instance_interruption_behavior = "stop" # preserve EBS data on interruption

  # Hibernation — only valid for on-demand instances (use_spot must be false)
  hibernation = var.hibernation

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
      delete_on_termination = true
    }
  ]

  # Provisioning variables are injected directly — no SSM parameter reads at boot.
  # SSH key and git identity come from the user registry; session_start.sh from scripts/.
  # To update session_start.sh on a running instance: ./admin.sh refresh <username>
  user_data_base64 = base64gzip(join("\n", [
    "#!/usr/bin/env bash",
    "# EC2 user data for ${var.project_name} / ${var.username}",
    "set -euo pipefail",
    "exec > >(tee /var/log/user-data.log | logger -t user-data) 2>&1",
    "echo '=== Claude Code environment bootstrap starting ==='",
    "",
    "# Provisioning variables injected by Terraform at provision time",
    "DEV_USERNAME='${var.username}'",
    "REGION='${var.aws_region}'",
    "PROJECT_NAME='${var.project_name}'",
    "SSH_PUBLIC_KEY='${var.ssh_public_key}'",
    "GIT_USER_NAME='${var.git_user_name}'",
    "GIT_USER_EMAIL='${var.git_user_email}'",
    "PREFERRED_SHELL='${var.preferred_shell}'",
    "AUTOSHUTDOWN_IDLE_MINUTES='${var.autoshutdown_idle_minutes}'",
    "DATA_VOLUME_ID='${var.data_volume_id}'",
    "",
    file("${path.module}/../user_data_main.sh"),
    local.admin_keys_block,
    "",
    "# ---------------------------------------------------------------------------",
    "# Session launcher — injected from scripts/session_start.sh at provision time",
    "# ---------------------------------------------------------------------------",
    "cat > /home/developer/session_start.sh << 'SESSION_LAUNCHER'",
    file("${path.module}/../../scripts/session_start.sh"),
    "SESSION_LAUNCHER",
    "chmod +x /home/developer/session_start.sh",
    "chown developer:developer /home/developer/session_start.sh",
    file("${path.module}/../user_data_tail.sh"),
  ]))
  user_data_replace_on_change = false

  tags = merge(local.owner_tags, {
    ProjectName = var.project_name
    Username    = var.username
  })
}

# ---------------------------------------------------------------------------
# Data volume attachment (conditional — only when data_volume_id is set)
# ---------------------------------------------------------------------------
# skip_destroy = true: when the EC2 instance is terminated, the volume detaches
# automatically; we don't want Terraform to block the destroy waiting to detach.
# The volume itself lives in a separate Terraform state (user-data/) and is never
# deleted by this module.
resource "aws_volume_attachment" "user_data" {
  count       = var.data_volume_id != "" ? 1 : 0
  device_name = "/dev/sdf"
  volume_id   = var.data_volume_id
  instance_id = module.user_ec2.id

  force_detach = false
  skip_destroy = true
}

# ---------------------------------------------------------------------------
# Explicit instance tagging — spot instance workaround
# ---------------------------------------------------------------------------
resource "aws_ec2_tag" "user_project_name" {
  resource_id = module.user_ec2.id
  key         = "ProjectName"
  value       = var.project_name
}

resource "aws_ec2_tag" "user_username" {
  resource_id = module.user_ec2.id
  key         = "Username"
  value       = var.username
}
