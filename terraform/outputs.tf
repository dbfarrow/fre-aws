output "vpc_id" {
  description = "VPC ID (shared across all user instances)."
  value       = module.vpc.vpc_id
}

output "network_mode" {
  description = "Active network mode."
  value       = var.network_mode
}

output "subnet_id" {
  description = "Subnet ID for user EC2 instances. Selected based on network_mode."
  value       = local.use_private_subnet ? module.vpc.private_subnets[0] : module.vpc.public_subnets[0]
}

output "associate_public_ip" {
  description = "Whether user EC2 instances receive a public IP. Derived from network_mode."
  value       = !local.use_private_subnet
}

output "security_group_id" {
  description = "EC2 security group ID shared across all user instances."
  value       = module.ec2_sg.security_group_id
}

output "app_url" {
  description = "Browser app URL (custom domain if set, otherwise CloudFront domain). Null if enable_web_app=false."
  value = try(
    var.app_domain != "" ? "https://${var.app_domain}" : "https://${aws_cloudfront_distribution.app[0].domain_name}",
    null
  )
}

output "app_cloudfront_distribution_id" {
  description = "CloudFront distribution ID for the browser app. Null if enable_web_app=false."
  value       = try(aws_cloudfront_distribution.app[0].id, null)
}

output "app_api_url" {
  description = "API Gateway invoke URL for the app API. Null if enable_web_app=false."
  value       = try(aws_apigatewayv2_stage.app_api[0].invoke_url, null)
}

output "billing_alerts" {
  description = "Summary of active billing alert configuration."
  value = local.billing_enabled ? join("\n", [
    "  Billing alerts:     enabled",
    "  Alert email:        ${var.billing_alert_email}",
    "  Monthly budget:     $${var.monthly_budget_usd} (alert at ${var.budget_alert_threshold_percent}%)",
    "  Zero-spend alert:   enabled (fires on first $0.01 of charges)",
    "  Anomaly detection:  enabled (alert threshold: $${var.anomaly_threshold_usd})",
  ]) : "  Billing alerts: disabled (set BILLING_ALERT_EMAIL in config/defaults.env to enable)"
}
