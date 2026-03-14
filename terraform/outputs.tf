output "instance_ids" {
  description = "Map of username to EC2 instance ID."
  value       = { for k, v in module.user_ec2 : k => v.id }
}

output "instance_states" {
  description = "Map of username to EC2 instance state."
  value       = { for k, v in module.user_ec2 : k => v.instance_state }
}

output "vpc_id" {
  description = "VPC ID (shared across all user instances)."
  value       = module.vpc.vpc_id
}

output "network_mode" {
  description = "Active network mode."
  value       = var.network_mode
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
