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

variable "existing_vpc_id" {
  description = "Existing VPC ID to deploy into instead of creating a new VPC. When set, existing_subnet_id must also be set. If the VPC does not exist in the configured region, up will fail."
  type        = string
  default     = ""
}

variable "existing_subnet_id" {
  description = "Existing subnet ID for EC2 instances. Required when existing_vpc_id is set. Must belong to existing_vpc_id."
  type        = string
  default     = ""
}

variable "owner_email" {
  description = "Email of the instance owner; used as a resource tag."
  type        = string
  default     = ""
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

# ---- Slack bot -------------------------------------------------------------

variable "enable_slack_bot" {
  description = "Deploy the admin Slack slash command bot (API Gateway + two Lambda functions). Requires SLACK_SIGNING_SECRET to be stored in Secrets Manager by bootstrap before Lambdas will work."
  type        = bool
  default     = false
}

variable "slack_command_name" {
  description = "Slash command name shown in usage text (without leading /). Must match the command name configured in the Slack App."
  type        = string
  default     = "fre"
}

variable "tf_backend_bucket" {
  description = "S3 bucket name for Terraform state — used by the Slack bot Lambda to read the user registry. Must match TF_BACKEND_BUCKET in config/backend.env."
  type        = string
  default     = ""
}

variable "tf_backend_region" {
  description = "AWS region of the Terraform state S3 bucket — used by the Slack bot Lambda for cross-region S3 access. Often us-east-1 (where bootstrap ran)."
  type        = string
  default     = "us-east-1"
}
