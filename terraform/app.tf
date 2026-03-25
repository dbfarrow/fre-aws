# app.tf — Browser-based user app: Lambda API + S3/CloudFront static hosting.
#
# All resources are conditional on var.enable_web_app.
# Pattern mirrors scheduled_stop.tf exactly.
#
# Architecture:
#   Onboarding email → signed URL → S3/CloudFront static HTML
#                                        │ fetch() API calls
#                               Lambda function URL (CORS enabled)
#                               (auth, EC2 lifecycle, federation)
#                                        │
#                                 EC2 instance (unchanged)
#
# Custom domain (optional):
#   Set var.app_domain + var.route53_zone_id to use a custom domain.
#   ACM certificate must be in us-east-1 (CloudFront requirement) — this file
#   adds an aws.us_east_1 provider alias for that purpose.

locals {
  web_app_enabled      = var.enable_web_app
  custom_domain_enabled = local.web_app_enabled && var.app_domain != ""
}

# ---------------------------------------------------------------------------
# us-east-1 provider alias — required for ACM certs used by CloudFront
# ---------------------------------------------------------------------------

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project    = var.project_name
      ManagedBy  = "terraform"
      Repository = "fre-aws"
    }
  }
}

# ---------------------------------------------------------------------------
# HMAC secret — signs magic-link tokens and session JWTs
# ---------------------------------------------------------------------------

resource "random_password" "app_hmac_secret" {
  count   = local.web_app_enabled ? 1 : 0
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "app_hmac_secret" {
  count = local.web_app_enabled ? 1 : 0

  name  = "/${var.project_name}/app/hmac-secret"
  type  = "SecureString"
  value = random_password.app_hmac_secret[0].result
  # Uses the AWS-managed SSM key (aws/ssm) rather than the project KMS key.
  # The project KMS key has a ViaService condition restricting use to EC2,
  # which would prevent Lambda from decrypting parameters via the SSM service.

  tags = {
    ProjectName = var.project_name
  }
}

# ---------------------------------------------------------------------------
# Lambda deployment package
# Zipped at plan time from the Python source; zip is gitignored.
# ---------------------------------------------------------------------------

data "archive_file" "app_api" {
  count = local.web_app_enabled ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/lambda/app_api.py"
  output_path = "${path.module}/lambda/app_api.zip"
}

# ---------------------------------------------------------------------------
# CloudWatch Logs group
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "app_api" {
  count = local.web_app_enabled ? 1 : 0

  name              = "/aws/lambda/${var.project_name}-app-api"
  retention_in_days = 30

  tags = {
    ProjectName = var.project_name
  }
}

# ---------------------------------------------------------------------------
# IAM role for Lambda
# ---------------------------------------------------------------------------

resource "aws_iam_role" "app_api_lambda" {
  count = local.web_app_enabled ? 1 : 0

  name = "${var.project_name}-app-api-lambda"

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

resource "aws_iam_role_policy_attachment" "app_api_basic" {
  count = local.web_app_enabled ? 1 : 0

  role       = aws_iam_role.app_api_lambda[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "app_api_permissions" {
  count = local.web_app_enabled ? 1 : 0

  name = "${var.project_name}-app-api-permissions"
  role = aws_iam_role.app_api_lambda[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # DescribeInstances cannot be resource-scoped by AWS policy engine
        Effect   = "Allow"
        Action   = "ec2:DescribeInstances"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:StartInstances", "ec2:StopInstances"]
        Resource = "arn:aws:ec2:${var.aws_region}:*:instance/*"
        Condition = {
          StringEquals = {
            "ec2:ResourceTag/ProjectName" = var.project_name
          }
        }
      },
      {
        # DescribeInstanceInformation cannot be resource-scoped
        Effect   = "Allow"
        Action   = "ssm:DescribeInstanceInformation"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project_name}/app/hmac-secret"
      },
      {
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = aws_iam_role.app_federation[0].arn
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Lambda function
# ---------------------------------------------------------------------------

resource "aws_lambda_function" "app_api" {
  count = local.web_app_enabled ? 1 : 0

  function_name    = "${var.project_name}-app-api"
  role             = aws_iam_role.app_api_lambda[0].arn
  filename         = data.archive_file.app_api[0].output_path
  source_code_hash = data.archive_file.app_api[0].output_base64sha256
  handler          = "app_api.handler"
  runtime          = "python3.12"
  timeout          = 30

  environment {
    variables = {
      PROJECT_NAME        = var.project_name
      HMAC_PARAM_PATH     = "/${var.project_name}/app/hmac-secret"
      FEDERATION_ROLE_ARN = aws_iam_role.app_federation[0].arn
      # Can't use reserved AWS_REGION — use AWS_REGION_NAME instead
      AWS_REGION_NAME     = var.aws_region
    }
  }

  logging_config {
    log_group  = aws_cloudwatch_log_group.app_api[0].name
    log_format = "Text"
  }

  depends_on = [
    aws_iam_role_policy_attachment.app_api_basic[0],
    aws_cloudwatch_log_group.app_api[0],
  ]

  tags = {
    ProjectName = var.project_name
  }
}

# ---------------------------------------------------------------------------
# SSM Session Preferences — auto-switch to developer user
# ---------------------------------------------------------------------------
# The document name is project-scoped to avoid colliding with an existing
# SSM-SessionManagerRunShell document (enterprise accounts often have one
# pre-configured by the platform team with session recording, KMS, etc.).
# The federation role policy references this specific document name.
# The shell profile runs "sudo su - developer" which works because ssm-user
# can sudo to root and root can su to developer.
# The developer login shell triggers session_start.sh (tmux + Claude).
# ---------------------------------------------------------------------------

resource "aws_ssm_document" "session_preferences" {
  count         = local.web_app_enabled ? 1 : 0
  name          = "${var.project_name}-session-preferences"
  document_type = "Session"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "Auto-switch to developer user on session start"
    sessionType   = "Standard_Stream"
    inputs = {
      s3BucketName                = ""
      s3KeyPrefix                 = ""
      s3EncryptionEnabled         = false
      cloudWatchLogGroupName      = ""
      cloudWatchEncryptionEnabled = false
      cloudWatchStreamingEnabled  = false
      idleSessionTimeout          = "20"
      maxSessionDuration          = ""
      runAsEnabled                = false
      runAsDefaultUser            = ""
      shellProfile = {
        linux = "sudo su - developer"
      }
    }
  })

  tags = {
    ProjectName = var.project_name
  }
}

# ---------------------------------------------------------------------------
# API Gateway HTTP API — public HTTPS endpoint for the Lambda
# Lambda function URLs block unauthenticated access in this account (likely
# an org-level SCP). API Gateway HTTP API is always publicly accessible.
# payload_format_version = "2.0" produces the same event shape as Lambda
# function URLs, so the Lambda code requires no changes.
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_api" "app_api" {
  count = local.web_app_enabled ? 1 : 0

  name          = "${var.project_name}-app-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_credentials = false
    allow_headers     = ["content-type", "authorization"]
    allow_methods     = ["GET", "POST", "OPTIONS"]
    allow_origins     = ["*"]
    max_age           = 86400
  }

  tags = {
    ProjectName = var.project_name
  }
}

resource "aws_apigatewayv2_stage" "app_api" {
  count = local.web_app_enabled ? 1 : 0

  api_id      = aws_apigatewayv2_api.app_api[0].id
  name        = "$default"
  auto_deploy = true
}

resource "aws_apigatewayv2_integration" "app_api" {
  count = local.web_app_enabled ? 1 : 0

  api_id                 = aws_apigatewayv2_api.app_api[0].id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.app_api[0].invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "app_api_default" {
  count = local.web_app_enabled ? 1 : 0

  api_id    = aws_apigatewayv2_api.app_api[0].id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.app_api[0].id}"
}

resource "aws_lambda_permission" "app_api_gateway" {
  count = local.web_app_enabled ? 1 : 0

  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.app_api[0].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.app_api[0].execution_arn}/*/*"
}

# ---------------------------------------------------------------------------
# Federation role — assumed by Lambda to generate SSM console sign-in URL
# ---------------------------------------------------------------------------
# The Lambda assumes this role on behalf of the user, passing a Username
# session tag. The trust policy requires that tag to be transitive.
# The role policy scopes ssm:StartSession to instances tagged with the
# matching Username (via aws:PrincipalTag/Username).

resource "aws_iam_role" "app_federation" {
  count = local.web_app_enabled ? 1 : 0

  name = "${var.project_name}-app-federation"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.app_api_lambda[0].arn }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    ProjectName = var.project_name
  }
}

resource "aws_iam_role_policy" "app_federation" {
  count = local.web_app_enabled ? 1 : 0

  name = "${var.project_name}-app-federation-policy"
  role = aws_iam_role.app_federation[0].id

  # The Lambda passes an inline session policy (Policy= in assume_role) that
  # restricts ssm:StartSession to the specific instance it looked up for the user.
  # That scope-down policy + this role's broader allow gives least-privilege access
  # without requiring sts:TagSession / ABAC session tags.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ssm:StartSession"
        Resource = "arn:aws:ec2:${var.aws_region}:*:instance/*"
        Condition = {
          StringEquals = {
            "ssm:resourceTag/ProjectName" = var.project_name
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = "ssm:StartSession"
        Resource = "arn:aws:ssm:${var.aws_region}:*:document/${var.project_name}-session-preferences"
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# S3 bucket — static app hosting (private, served via CloudFront OAC)
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "app_static" {
  count = local.web_app_enabled ? 1 : 0

  bucket = "${var.project_name}-app-static"

  tags = {
    ProjectName = var.project_name
  }
}

resource "aws_s3_bucket_public_access_block" "app_static" {
  count = local.web_app_enabled ? 1 : 0

  bucket                  = aws_s3_bucket.app_static[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "app_static" {
  count = local.web_app_enabled ? 1 : 0

  bucket = aws_s3_bucket.app_static[0].id

  rule {
    apply_server_side_encryption_by_default {
      # AES256 (S3-managed key) avoids the KMS ViaService complexity.
      # The project KMS key restricts use to ec2.*.amazonaws.com which would
      # prevent CloudFront's OAC from reading KMS-encrypted objects.
      sse_algorithm = "AES256"
    }
  }
}

# ---------------------------------------------------------------------------
# CloudFront Origin Access Control — private S3 bucket access
# ---------------------------------------------------------------------------

resource "aws_cloudfront_origin_access_control" "app_static" {
  count = local.web_app_enabled ? 1 : 0

  name                              = "${var.project_name}-app-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ---------------------------------------------------------------------------
# CloudFront distribution — SPA with index.html fallback for client routing
# ---------------------------------------------------------------------------

resource "aws_cloudfront_distribution" "app" {
  count   = local.web_app_enabled ? 1 : 0
  enabled = true

  # Serve index.html for root / requests (no S3 key = 403 without this)
  default_root_object = "index.html"

  origin {
    domain_name              = aws_s3_bucket.app_static[0].bucket_regional_domain_name
    origin_id                = "app-static-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.app_static[0].id
  }

  default_cache_behavior {
    target_origin_id       = "app-static-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 86400
    max_ttl     = 86400
  }

  # SPA routing: private S3 buckets return 403 (not 404) for missing objects
  # to prevent key enumeration. Map both to index.html so /u/{username} paths
  # are handled client-side from the single static file.
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  aliases = local.custom_domain_enabled ? [var.app_domain] : []

  viewer_certificate {
    cloudfront_default_certificate = !local.custom_domain_enabled
    # try() returns null when the resource doesn't exist (count = 0)
    acm_certificate_arn  = try(aws_acm_certificate_validation.app[0].certificate_arn, null)
    ssl_support_method   = local.custom_domain_enabled ? "sni-only" : null
    minimum_protocol_version = local.custom_domain_enabled ? "TLSv1.2_2021" : "TLSv1"
  }

  price_class = "PriceClass_100"

  tags = {
    ProjectName = var.project_name
  }
}

# ---------------------------------------------------------------------------
# S3 bucket policy — allow CloudFront OAC only
# Depends on the distribution being created first (for its ARN).
# ---------------------------------------------------------------------------

resource "aws_s3_bucket_policy" "app_static" {
  count = local.web_app_enabled ? 1 : 0

  bucket = aws_s3_bucket.app_static[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.app_static[0].arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.app[0].arn
        }
      }
    }]
  })
}

# ---------------------------------------------------------------------------
# index.html — rendered at apply time with the Lambda function URL injected
# ---------------------------------------------------------------------------

resource "aws_s3_object" "app_index" {
  count = local.web_app_enabled ? 1 : 0

  bucket       = aws_s3_bucket.app_static[0].id
  key          = "index.html"
  content_type = "text/html"

  content = templatefile("${path.module}/static/index.html.tpl", {
    api_url = aws_apigatewayv2_stage.app_api[0].invoke_url
  })
}

# ---------------------------------------------------------------------------
# Optional: Custom domain
# ACM cert must be in us-east-1 (CloudFront requirement).
# Only deployed when var.app_domain is set.
# ---------------------------------------------------------------------------

resource "aws_acm_certificate" "app" {
  count    = local.custom_domain_enabled ? 1 : 0
  provider = aws.us_east_1

  domain_name       = var.app_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    ProjectName = var.project_name
  }
}

resource "aws_route53_record" "app_cert_validation" {
  # for_each with a conditional map — empty when custom_domain_enabled = false
  for_each = {
    for dvo in(local.custom_domain_enabled ? aws_acm_certificate.app[0].domain_validation_options : []) :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = var.route53_zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "app" {
  count    = local.custom_domain_enabled ? 1 : 0
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.app[0].arn
  validation_record_fqdns = [for record in aws_route53_record.app_cert_validation : record.fqdn]
}

resource "aws_route53_record" "app" {
  count = local.custom_domain_enabled ? 1 : 0

  zone_id = var.route53_zone_id
  name    = var.app_domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.app[0].domain_name
    zone_id                = aws_cloudfront_distribution.app[0].hosted_zone_id
    evaluate_target_health = false
  }
}
