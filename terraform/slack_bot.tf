# slack_bot.tf — Slack slash command bot: API Gateway + two Lambda functions.
#
# All resources are conditional on var.enable_slack_bot.
#
# Architecture:
#   Slack → API Gateway POST /slack
#        → slack-handler Lambda (sync, 10s timeout)
#             signing secret loaded at module init (absorbed by Lambda Init phase)
#             verify HMAC-SHA256 signature
#             parse body + validate subcommand
#             invoke slack-notifier async (fire-and-forget)
#             return ephemeral ACK to Slack (< 3s, even on cold start)
#        → slack-notifier Lambda (async, 120s timeout)
#             auth: S3 user registry slack_user_id + role==admin
#             dispatch: list / start / stop (with EC2 waiters for start/stop)
#             POST result to Slack response_url
#
# Signing secret lives in Secrets Manager ({project}/slack/signing-secret).
# Bootstrap writes it; Terraform only reads the secret via IAM — never stores it in state.

locals {
  slack_enabled = var.enable_slack_bot
}

# ---------------------------------------------------------------------------
# Lambda deployment package
# ---------------------------------------------------------------------------

data "archive_file" "slack_bot" {
  count       = local.slack_enabled ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/lambda/slack_bot.py"
  output_path = "${path.module}/lambda/slack_bot.zip"
}

# ---------------------------------------------------------------------------
# CloudWatch log groups (explicit so retention is set; created before Lambdas)
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "slack_handler" {
  count             = local.slack_enabled ? 1 : 0
  name              = "/aws/lambda/${var.project_name}-slack-handler"
  retention_in_days = 30
  tags = {
    ProjectName = var.project_name
  }
}

resource "aws_cloudwatch_log_group" "slack_notifier" {
  count             = local.slack_enabled ? 1 : 0
  name              = "/aws/lambda/${var.project_name}-slack-notifier"
  retention_in_days = 30
  tags = {
    ProjectName = var.project_name
  }
}

# ---------------------------------------------------------------------------
# slack-notifier Lambda (async — waits for EC2 state, POSTs to Slack)
# ---------------------------------------------------------------------------

resource "aws_iam_role" "slack_notifier" {
  count = local.slack_enabled ? 1 : 0
  name  = "${var.project_name}-slack-notifier"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "slack_notifier_logs" {
  count      = local.slack_enabled ? 1 : 0
  role       = aws_iam_role.slack_notifier[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "slack_notifier_ec2" {
  count = local.slack_enabled ? 1 : 0
  name  = "ec2-lifecycle"
  role  = aws_iam_role.slack_notifier[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ec2:DescribeInstances"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:StartInstances",
          "ec2:StopInstances",
        ]
        Resource = "arn:aws:ec2:${var.aws_region}:*:instance/*"
        Condition = {
          StringEquals = {
            "ec2:ResourceTag/ProjectName" = var.project_name
          }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy" "slack_notifier_s3" {
  count = local.slack_enabled ? 1 : 0
  name  = "s3-user-registry"
  role  = aws_iam_role.slack_notifier[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "s3:GetObject"
      Resource = "arn:aws:s3:::${var.tf_backend_bucket}/${var.project_name}/users.json"
    }]
  })
}

resource "aws_iam_role_policy" "slack_notifier_ssm" {
  count = local.slack_enabled ? 1 : 0
  name  = "ssm-run-command"
  role  = aws_iam_role.slack_notifier[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ssm:SendCommand"
        Resource = "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript"
      },
      {
        Effect   = "Allow"
        Action   = "ssm:SendCommand"
        Resource = "arn:aws:ec2:${var.aws_region}:*:instance/*"
        Condition = {
          StringEquals = {
            "ssm:resourceTag/ProjectName" = var.project_name
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = [
          "ssm:DescribeInstanceInformation",
          "ssm:GetCommandInvocation",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_lambda_function" "slack_notifier" {
  count         = local.slack_enabled ? 1 : 0
  function_name = "${var.project_name}-slack-notifier"
  role          = aws_iam_role.slack_notifier[0].arn
  runtime       = "python3.12"
  handler       = "slack_bot.handle_notify"
  timeout       = 300
  filename      = data.archive_file.slack_bot[0].output_path
  source_code_hash = data.archive_file.slack_bot[0].output_base64sha256

  environment {
    variables = {
      PROJECT_NAME      = var.project_name
      TF_BACKEND_BUCKET = var.tf_backend_bucket
      TF_BACKEND_REGION = var.tf_backend_region
    }
  }

  depends_on = [aws_cloudwatch_log_group.slack_notifier]
}

# ---------------------------------------------------------------------------
# slack-handler Lambda (sync — verifies Slack request, dispatches)
# ---------------------------------------------------------------------------

resource "aws_iam_role" "slack_handler" {
  count = local.slack_enabled ? 1 : 0
  name  = "${var.project_name}-slack-handler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "slack_handler_logs" {
  count      = local.slack_enabled ? 1 : 0
  role       = aws_iam_role.slack_handler[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "slack_handler_ec2" {
  count = local.slack_enabled ? 1 : 0
  name  = "ec2-lifecycle"
  role  = aws_iam_role.slack_handler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ec2:DescribeInstances"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:StartInstances",
          "ec2:StopInstances",
        ]
        Resource = "arn:aws:ec2:${var.aws_region}:*:instance/*"
        Condition = {
          StringEquals = {
            "ec2:ResourceTag/ProjectName" = var.project_name
          }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy" "slack_handler_sm" {
  count = local.slack_enabled ? 1 : 0
  name  = "secrets-manager-signing-secret"
  role  = aws_iam_role.slack_handler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = "arn:aws:secretsmanager:${var.aws_region}:*:secret:${var.project_name}/slack/signing-secret*"
    }]
  })
}

resource "aws_iam_role_policy" "slack_handler_s3" {
  count = local.slack_enabled ? 1 : 0
  name  = "s3-user-registry"
  role  = aws_iam_role.slack_handler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "s3:GetObject"
      Resource = "arn:aws:s3:::${var.tf_backend_bucket}/${var.project_name}/users.json"
    }]
  })
}

resource "aws_iam_role_policy" "slack_handler_lambda" {
  count = local.slack_enabled ? 1 : 0
  name  = "invoke-notifier"
  role  = aws_iam_role.slack_handler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.slack_notifier[0].arn
    }]
  })
}

resource "aws_lambda_function" "slack_handler" {
  count         = local.slack_enabled ? 1 : 0
  function_name = "${var.project_name}-slack-handler"
  role          = aws_iam_role.slack_handler[0].arn
  runtime       = "python3.12"
  handler       = "slack_bot.handle_command"
  timeout       = 10
  filename      = data.archive_file.slack_bot[0].output_path
  source_code_hash = data.archive_file.slack_bot[0].output_base64sha256

  environment {
    variables = {
      PROJECT_NAME           = var.project_name
      SLACK_COMMAND_NAME     = var.slack_command_name
      TF_BACKEND_BUCKET      = var.tf_backend_bucket
      TF_BACKEND_REGION      = var.tf_backend_region
      NOTIFIER_FUNCTION_NAME = aws_lambda_function.slack_notifier[0].function_name
    }
  }

  depends_on = [aws_cloudwatch_log_group.slack_handler]
}

# ---------------------------------------------------------------------------
# API Gateway HTTP API (POST /slack)
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_api" "slack" {
  count         = local.slack_enabled ? 1 : 0
  name          = "${var.project_name}-slack-bot"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_stage" "slack" {
  count       = local.slack_enabled ? 1 : 0
  api_id      = aws_apigatewayv2_api.slack[0].id
  name        = "$default"
  auto_deploy = true
}

resource "aws_apigatewayv2_integration" "slack" {
  count                  = local.slack_enabled ? 1 : 0
  api_id                 = aws_apigatewayv2_api.slack[0].id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.slack_handler[0].invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "slack" {
  count     = local.slack_enabled ? 1 : 0
  api_id    = aws_apigatewayv2_api.slack[0].id
  route_key = "POST /slack"
  target    = "integrations/${aws_apigatewayv2_integration.slack[0].id}"
}

resource "aws_lambda_permission" "slack_api_gw" {
  count         = local.slack_enabled ? 1 : 0
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack_handler[0].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.slack[0].execution_arn}/*/*"
}
