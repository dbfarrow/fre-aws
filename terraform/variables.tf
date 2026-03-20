variable "project_name" {
  description = "Unique name for this project; used as a prefix for all resource names and the S3 state bucket."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,24}$", var.project_name))
    error_message = "project_name must be 3-25 characters, start with a letter, and contain only lowercase letters, numbers, and hyphens."
  }
}

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}


variable "instance_type" {
  description = "EC2 instance type. t3.micro is Free Tier eligible for the first 12 months."
  type        = string
  default     = "t3.micro"
}

variable "use_spot" {
  description = <<-EOT
    Use EC2 Spot instances to reduce cost (60-90% cheaper than on-demand).
    Spot instances can be interrupted with 2-minute notice; EBS data is preserved on stop.

    WARNING — BREAKING CHANGE: changing this value on an existing environment destroys
    and recreates ALL instances. Terraform switches the underlying resource type
    (aws_spot_instance_request vs aws_instance), forcing replacement regardless of
    user_data_replace_on_change. Only change before initial provisioning, or when
    reprovisioning every instance from scratch is acceptable.
  EOT
  type        = bool
  default     = false
}

variable "network_mode" {
  description = <<-EOT
    Controls VPC and EC2 network topology:
      public           - EC2 in public subnet with public IP, no NAT (Free Tier friendly, single security group layer)
      private_nat      - EC2 in private subnet, outbound via NAT Gateway (~$33/month, defense in depth)
      private_endpoints - EC2 in private subnet, SSM via VPC endpoints (~$22/month, no general internet access)
  EOT
  type        = string
  default     = "public"

  validation {
    condition     = contains(["public", "private_nat", "private_endpoints"], var.network_mode)
    error_message = "network_mode must be one of: public, private_nat, private_endpoints."
  }
}

variable "ebs_volume_size_gb" {
  description = "Root EBS volume size in GB. Free Tier includes 30 GB. Must be >= the AMI's root snapshot size (typically 30 GB for Amazon Linux 2023)."
  type        = number
  default     = 30
}

variable "owner_email" {
  description = "Email of the instance owner; used as a resource tag."
  type        = string
  default     = ""
}

variable "admin_ssh_keys" {
  description = "SSH public keys for admin access to all user instances. Auto-populated from the admin's SSH key by up.sh."
  type        = list(string)
  default     = []
}

variable "users" {
  description = "Map of usernames to per-user configuration. Each entry creates a dedicated EC2 instance. See config/users.tfvars.example."
  type = map(object({
    ssh_public_key = string
    git_user_name  = string
    git_user_email = string
  }))
  default = {}
}

# ---- Billing ---------------------------------------------------------------

variable "billing_alert_email" {
  description = "Email address to receive billing alerts and anomaly notifications. Leave empty to skip all billing resources."
  type        = string
  default     = ""
}

variable "monthly_budget_usd" {
  description = "Monthly spend budget in USD. Alerts fire when actual or forecasted spend exceeds budget_alert_threshold_percent of this value."
  type        = number
  default     = 10
}

variable "budget_alert_threshold_percent" {
  description = "Percentage of monthly_budget_usd at which budget alerts are sent (applies to both actual and forecasted spend)."
  type        = number
  default     = 80
}

variable "anomaly_threshold_usd" {
  description = "Minimum anomaly impact in USD before a cost anomaly alert is sent. Anomalies below this amount are suppressed."
  type        = number
  default     = 5
}

variable "enable_anomaly_detection" {
  description = "Create Cost Explorer anomaly monitor and subscription. AWS limits accounts to one DIMENSIONAL monitor; set to false if your account already has one or hits the limit."
  type        = bool
  default     = true
}

variable "enable_scheduled_stop" {
  description = "Stop all running instances automatically at midnight Pacific time. Prevents forgotten instances from running overnight and incurring charges."
  type        = bool
  default     = true
}

# ---- Web app ---------------------------------------------------------------

variable "enable_web_app" {
  description = "Deploy the browser-based user app (Lambda + S3 + CloudFront). Set to true after bootstrapping to provide users with a zero-install path."
  type        = bool
  default     = false
}

variable "app_domain" {
  description = "Custom domain for the browser app (e.g. app.myproject.com). Leave empty to use the auto-generated CloudFront domain."
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = "Route 53 hosted zone ID for app_domain. Required if app_domain is set."
  type        = string
  default     = ""
}
