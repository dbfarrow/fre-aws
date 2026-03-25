# ---------------------------------------------------------------------------
# Base outputs — wired from base module by up.sh after Phase 1 apply
# ---------------------------------------------------------------------------

variable "project_name" {
  description = "Project name; matches the base module's project_name."
  type        = string
}

variable "aws_region" {
  description = "AWS region; matches the base module's aws_region."
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID for the EC2 instance. Pre-selected by the base module based on network_mode."
  type        = string
}

variable "associate_public_ip" {
  description = "Whether to assign a public IP. Derived from network_mode in the base module."
  type        = bool
}

variable "security_group_id" {
  description = "Security group ID for the EC2 instance. Created by the base module."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN for EBS encryption. Created by the base module."
  type        = string
}

# ---------------------------------------------------------------------------
# Per-user identity
# ---------------------------------------------------------------------------

variable "username" {
  description = "Username for this EC2 instance. Must match the user registry entry."
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key for the developer user on this instance."
  type        = string
}

variable "git_user_name" {
  description = "Git user.name to configure on this instance."
  type        = string
}

variable "git_user_email" {
  description = "Git user.email to configure on this instance."
  type        = string
}

# ---------------------------------------------------------------------------
# Per-user instance config
# ---------------------------------------------------------------------------

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.micro"
}

variable "use_spot" {
  description = <<-EOT
    Use EC2 Spot instances to reduce cost (60-90% cheaper than on-demand).
    Spot instances can be interrupted with 2-minute notice; EBS data is preserved on stop.
  EOT
  type        = bool
  default     = false
}

variable "ebs_volume_size_gb" {
  description = "Root EBS volume size in GB."
  type        = number
  default     = 30
}

variable "owner_email" {
  description = "Email of the instance owner; used as a resource tag."
  type        = string
  default     = ""
}

variable "admin_ssh_keys" {
  description = "Additional SSH public keys to append to authorized_keys for admin access."
  type        = list(string)
  default     = []
}

variable "ami_id" {
  description = <<-EOT
    AMI ID to use for the EC2 instance. When set, Terraform uses this exact AMI
    instead of fetching the latest AL2023 AMI — preventing unintended instance
    replacement when Amazon publishes a new AMI. up.sh populates this from the
    running instance's current AMI. Leave empty ("") to use the latest AMI
    (correct for new instances that have never been provisioned).
  EOT
  type        = string
  default     = ""
}
