# scheduled_stop.tf — Midnight Pacific auto-stop for all project instances.
#
# Uses EventBridge Scheduler (not classic EventBridge rules) for timezone-aware
# scheduling with automatic DST handling — no need for two rules to cover PST/PDT.
#
# All resources are conditional on var.enable_scheduled_stop.
# Set ENABLE_SCHEDULED_STOP=false in config/admin.env to disable.

locals {
  stop_enabled = var.enable_scheduled_stop
}

# ---------------------------------------------------------------------------
# Lambda deployment package
# Zipped at plan time from the Python source; zip is gitignored.
# ---------------------------------------------------------------------------

data "archive_file" "scheduled_stop" {
  count = local.stop_enabled ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/lambda/scheduled_stop.py"
  output_path = "${path.module}/lambda/scheduled_stop.zip"
}

# ---------------------------------------------------------------------------
# CloudWatch Logs group
# Created explicitly (not auto-created) to enforce retention and project tags.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "scheduled_stop" {
  count = local.stop_enabled ? 1 : 0

  name              = "/aws/lambda/${var.project_name}-scheduled-stop"
  retention_in_days = 30

  tags = {
    ProjectName = var.project_name
  }
}

# ---------------------------------------------------------------------------
# IAM role for Lambda
# ---------------------------------------------------------------------------

resource "aws_iam_role" "scheduled_stop_lambda" {
  count = local.stop_enabled ? 1 : 0

  name = "${var.project_name}-scheduled-stop-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    ProjectName = var.project_name
  }
}

# Basic execution role — covers CloudWatch Logs write access
resource "aws_iam_role_policy_attachment" "scheduled_stop_basic" {
  count = local.stop_enabled ? 1 : 0

  role       = aws_iam_role.scheduled_stop_lambda[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# EC2 permissions — tag-conditioned StopInstances, unrestricted DescribeInstances
# (Describe actions cannot be resource-scoped by AWS policy engine)
resource "aws_iam_role_policy" "scheduled_stop_ec2" {
  count = local.stop_enabled ? 1 : 0

  name = "${var.project_name}-scheduled-stop-ec2"
  role = aws_iam_role.scheduled_stop_lambda[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ec2:DescribeInstances"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "ec2:StopInstances"
        Resource = "arn:aws:ec2:${var.aws_region}:*:instance/*"
        Condition = {
          StringEquals = {
            "ec2:ResourceTag/ProjectName" = var.project_name
          }
        }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Lambda function
# ---------------------------------------------------------------------------

resource "aws_lambda_function" "scheduled_stop" {
  count = local.stop_enabled ? 1 : 0

  function_name    = "${var.project_name}-scheduled-stop"
  role             = aws_iam_role.scheduled_stop_lambda[0].arn
  filename         = data.archive_file.scheduled_stop[0].output_path
  source_code_hash = data.archive_file.scheduled_stop[0].output_base64sha256
  handler          = "scheduled_stop.handler"
  runtime          = "python3.12"

  environment {
    variables = {
      PROJECT_NAME = var.project_name
    }
  }

  logging_config {
    log_group  = aws_cloudwatch_log_group.scheduled_stop[0].name
    log_format = "Text"
  }

  depends_on = [
    aws_iam_role_policy_attachment.scheduled_stop_basic[0],
    aws_cloudwatch_log_group.scheduled_stop[0],
  ]

  tags = {
    ProjectName = var.project_name
  }
}

# ---------------------------------------------------------------------------
# Permission for EventBridge Scheduler to invoke Lambda
# ---------------------------------------------------------------------------

resource "aws_lambda_permission" "scheduled_stop" {
  count = local.stop_enabled ? 1 : 0

  statement_id  = "AllowScheduler"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scheduled_stop[0].function_name
  principal     = "scheduler.amazonaws.com"
}

# ---------------------------------------------------------------------------
# IAM role for EventBridge Scheduler to invoke Lambda
# Separate from the Lambda execution role — the scheduler assumes this role
# to call lambda:InvokeFunction on the target.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "scheduled_stop_scheduler" {
  count = local.stop_enabled ? 1 : 0

  name = "${var.project_name}-scheduled-stop-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    ProjectName = var.project_name
  }
}

resource "aws_iam_role_policy" "scheduled_stop_scheduler_invoke" {
  count = local.stop_enabled ? 1 : 0

  name = "${var.project_name}-scheduled-stop-invoke"
  role = aws_iam_role.scheduled_stop_scheduler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.scheduled_stop[0].arn
    }]
  })
}

# ---------------------------------------------------------------------------
# EventBridge Scheduler — midnight Pacific, DST-aware
# ---------------------------------------------------------------------------

resource "aws_scheduler_schedule" "midnight_stop" {
  count = local.stop_enabled ? 1 : 0

  name = "${var.project_name}-midnight-stop"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = "cron(0 0 * * ? *)"
  schedule_expression_timezone = "America/Los_Angeles"

  target {
    arn      = aws_lambda_function.scheduled_stop[0].arn
    role_arn = aws_iam_role.scheduled_stop_scheduler[0].arn
  }
}
