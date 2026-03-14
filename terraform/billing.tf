# billing.tf — Budget alerts and cost anomaly detection.
#
# All resources are conditional on billing_alert_email being set.
# Set BILLING_ALERT_EMAIL in config/defaults.env to enable.
#
# Free tier note: AWS allows 2 free budgets/month. This file creates exactly 2:
#   1. monthly_spend  — alerts at a configurable % of your monthly budget
#   2. zero_spend     — alerts the moment any charges appear (free tier sentinel)
#
# Cost anomaly detection is free regardless of the number of monitors.

locals {
  billing_enabled = var.billing_alert_email != ""
}

# ---------------------------------------------------------------------------
# Monthly spend budget
# Sends alerts when actual spend OR forecasted spend crosses the threshold.
# ---------------------------------------------------------------------------

resource "aws_budgets_budget" "monthly_spend" {
  count = local.billing_enabled ? 1 : 0

  name         = "${var.project_name}-monthly-spend"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Alert when actual spend exceeds threshold
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = var.budget_alert_threshold_percent
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.billing_alert_email]
  }

  # Alert when forecasted spend is on track to exceed threshold
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = var.budget_alert_threshold_percent
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.billing_alert_email]
  }
}

# ---------------------------------------------------------------------------
# Zero-spend sentinel budget
# Fires the moment actual charges exceed $0.01 — catches unexpected costs
# immediately on a free-tier account.
# ---------------------------------------------------------------------------

resource "aws_budgets_budget" "zero_spend" {
  count = local.billing_enabled ? 1 : 0

  name         = "${var.project_name}-zero-spend"
  budget_type  = "COST"
  limit_amount = "0.01"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.billing_alert_email]
  }
}

# ---------------------------------------------------------------------------
# Cost anomaly detection
# ML-based detection of unexpected spending spikes. Free to use.
# Monitors all AWS services and sends a daily digest of anomalies above
# the configured dollar threshold.
# ---------------------------------------------------------------------------

resource "aws_ce_anomaly_monitor" "main" {
  count = local.billing_enabled ? 1 : 0

  name              = "${var.project_name}-anomaly-monitor"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

resource "aws_ce_anomaly_subscription" "main" {
  count = local.billing_enabled ? 1 : 0

  name      = "${var.project_name}-anomaly-alerts"
  frequency = "DAILY"

  monitor_arn_list = [aws_ce_anomaly_monitor.main[0].arn]

  subscriber {
    type    = "EMAIL"
    address = var.billing_alert_email
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.anomaly_threshold_usd)]
    }
  }
}
