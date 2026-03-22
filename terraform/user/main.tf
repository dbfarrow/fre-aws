locals {
  # Tag all resources with owner if provided
  owner_tags = var.owner_email != "" ? { Owner = var.owner_email } : {}

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
    values = ["al2023-ami-*-x86_64"]
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

resource "aws_iam_instance_profile" "user_ec2" {
  name = "${var.project_name}-${var.username}-ec2-profile"
  role = aws_iam_role.user_ec2.name
}

# ---------------------------------------------------------------------------
# EC2 instance
# ---------------------------------------------------------------------------

module "user_ec2" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 5.0"

  name = "${var.project_name}-${var.username}-dev"

  ami           = data.aws_ami.amazon_linux_2023.id
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
      kms_key_id            = var.kms_key_arn
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
    "",
    file("${path.module}/../user_data_main.sh"),
    local.admin_keys_block,
    "",
    "# ---------------------------------------------------------------------------",
    "# tmux configuration — injected from config/tmux.conf at provision time",
    "# ---------------------------------------------------------------------------",
    "cat > /home/developer/.tmux.conf << 'TMUXCONF'",
    file("${path.module}/../../config/tmux.conf"),
    "TMUXCONF",
    "chown developer:developer /home/developer/.tmux.conf",
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

  lifecycle {
    # Prevent routine `up` runs from replacing the instance when Amazon
    # publishes a new AL2023 AMI. To intentionally update the AMI, taint
    # the resource: terraform taint module.user_ec2.aws_instance.this[0]
    ignore_changes = [ami]
  }

  tags = merge(local.owner_tags, {
    ProjectName = var.project_name
    Username    = var.username
  })
}

# ---------------------------------------------------------------------------
# Explicit instance tagging — spot instance workaround
# ---------------------------------------------------------------------------
# terraform-aws-modules/ec2-instance propagates tags to spot instances via
# aws_ec2_tag resources inside the module, but those can fail silently during
# apply (the spot_instance_id is "known after apply" and the apply may partially
# succeed). Adding these at the root level ensures tags are (re)applied on every
# terraform apply, using the module's id output which correctly returns the EC2
# instance ID (not the spot request ID) once the spot is fulfilled.

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
