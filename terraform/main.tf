terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = var.tags
  }
}

# WAF must be in us-east-1 for CloudFront
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  default_tags {
    tags = var.tags
  }
}

locals {
  prefix = "${var.project_name}-${var.environment}"
}

# ─────────────────────────────────────────────
# DATA: Package Lambda functions as ZIP
# ─────────────────────────────────────────────

data "archive_file" "purchase" {
  type        = "zip"
  source_file = "${path.module}/../lambda/purchase.py"
  output_path = "${path.module}/../.build/purchase.zip"
}

data "archive_file" "payment" {
  type        = "zip"
  source_file = "${path.module}/../lambda/payment.py"
  output_path = "${path.module}/../.build/payment.zip"
}

data "archive_file" "cleanup" {
  type        = "zip"
  source_file = "${path.module}/../lambda/cleanup.py"
  output_path = "${path.module}/../.build/cleanup.zip"
}

# ─────────────────────────────────────────────
# DYNAMODB — Ticket inventory + reservations
# ─────────────────────────────────────────────

resource "aws_dynamodb_table" "tickets" {
  name         = "${local.prefix}-tickets"
  billing_mode = var.dynamodb_billing_mode
  hash_key     = "EventID"
  range_key    = "Tier"

  attribute {
    name = "EventID"
    type = "S"
  }

  attribute {
    name = "Tier"
    type = "S"
  }

  # TTL for auto-expiring reservations (sub-second inventory recovery via streams)
  ttl {
    attribute_name = "TTL"
    enabled        = true
  }

  # Stream for cleanup Lambda to catch TTL expirations
  stream_enabled   = true
  stream_view_type = "OLD_IMAGE"

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true  # Uses AWS-managed KMS key
  }

  tags = { Name = "${local.prefix}-tickets" }
}

# ─────────────────────────────────────────────
# SQS — Payment queue (FIFO for ordering)
# ─────────────────────────────────────────────

resource "aws_sqs_queue" "payment_dlq" {
  name                      = "${local.prefix}-payment-dlq.fifo"
  fifo_queue                = true
  content_based_deduplication = true
  message_retention_seconds = 1209600  # 14 days
  tags                      = { Name = "${local.prefix}-payment-dlq" }
}

resource "aws_sqs_queue" "payment_queue" {
  name                        = "${local.prefix}-payment.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  visibility_timeout_seconds  = var.sqs_visibility_timeout
  message_retention_seconds   = 86400  # 24 hours

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.payment_dlq.arn
    maxReceiveCount     = 3
  })

  tags = { Name = "${local.prefix}-payment-queue" }
}

# ─────────────────────────────────────────────
# IAM — Lambda execution roles
# ─────────────────────────────────────────────

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "purchase_lambda" {
  name               = "${local.prefix}-purchase-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "purchase_lambda" {
  name = "${local.prefix}-purchase-policy"
  role = aws_iam_role.purchase_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.tickets.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.payment_queue.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_iam_role" "payment_lambda" {
  name               = "${local.prefix}-payment-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "payment_lambda" {
  name = "${local.prefix}-payment-policy"
  role = aws_iam_role.payment_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.tickets.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.payment_queue.arn
      },
      {
        Effect   = "Allow"
        Action   = ["events:PutEvents"]
        Resource = aws_cloudwatch_event_bus.main.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_iam_role" "cleanup_lambda" {
  name               = "${local.prefix}-cleanup-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "cleanup_lambda" {
  name = "${local.prefix}-cleanup-policy"
  role = aws_iam_role.cleanup_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:Scan", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:GetRecords", "dynamodb:GetShardIterator", "dynamodb:DescribeStream", "dynamodb:ListStreams"]
        Resource = [aws_dynamodb_table.tickets.arn, "${aws_dynamodb_table.tickets.arn}/stream/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["events:PutEvents"]
        Resource = aws_cloudwatch_event_bus.main.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# ─────────────────────────────────────────────
# LAMBDA — Functions
# ─────────────────────────────────────────────

resource "aws_lambda_function" "purchase" {
  function_name    = "${local.prefix}-purchase"
  role             = aws_iam_role.purchase_lambda.arn
  runtime          = "python3.12"
  handler          = "purchase.lambda_handler"
  filename         = data.archive_file.purchase.output_path
  source_code_hash = data.archive_file.purchase.output_base64sha256
  memory_size      = var.lambda_memory_mb
  timeout          = var.lambda_timeout_seconds

  environment {
    variables = {
      DYNAMODB_TABLE = aws_dynamodb_table.tickets.name
      SQS_QUEUE_URL  = aws_sqs_queue.payment_queue.url
      ENVIRONMENT    = var.environment
    }
  }

  tags = { Name = "${local.prefix}-purchase" }
}

resource "aws_lambda_function" "payment" {
  function_name    = "${local.prefix}-payment"
  role             = aws_iam_role.payment_lambda.arn
  runtime          = "python3.12"
  handler          = "payment.lambda_handler"
  filename         = data.archive_file.payment.output_path
  source_code_hash = data.archive_file.payment.output_base64sha256
  memory_size      = var.lambda_memory_mb
  timeout          = var.lambda_timeout_seconds

  environment {
    variables = {
      DYNAMODB_TABLE   = aws_dynamodb_table.tickets.name
      EVENT_BUS_NAME   = aws_cloudwatch_event_bus.main.name
      SES_SENDER_EMAIL = var.ses_sender_email
      ENVIRONMENT      = var.environment
    }
  }

  tags = { Name = "${local.prefix}-payment" }
}

resource "aws_lambda_function" "cleanup" {
  function_name    = "${local.prefix}-cleanup"
  role             = aws_iam_role.cleanup_lambda.arn
  runtime          = "python3.12"
  handler          = "cleanup.lambda_handler"
  filename         = data.archive_file.cleanup.output_path
  source_code_hash = data.archive_file.cleanup.output_base64sha256
  memory_size      = 256
  timeout          = 60

  environment {
    variables = {
      DYNAMODB_TABLE = aws_dynamodb_table.tickets.name
      EVENT_BUS_NAME = aws_cloudwatch_event_bus.main.name
      ENVIRONMENT    = var.environment
    }
  }

  tags = { Name = "${local.prefix}-cleanup" }
}

# ─────────────────────────────────────────────
# LAMBDA EVENT SOURCE MAPPINGS
# ─────────────────────────────────────────────

# Payment Lambda triggered by SQS
resource "aws_lambda_event_source_mapping" "payment_sqs" {
  event_source_arn = aws_sqs_queue.payment_queue.arn
  function_name    = aws_lambda_function.payment.arn
  batch_size       = 10
  enabled          = true
}

# Cleanup Lambda triggered by DynamoDB Streams
resource "aws_lambda_event_source_mapping" "cleanup_stream" {
  event_source_arn  = aws_dynamodb_table.tickets.stream_arn
  function_name     = aws_lambda_function.cleanup.arn
  starting_position = "LATEST"
  batch_size        = 100
  enabled           = true

  filter_criteria {
    filter {
      pattern = jsonencode({ eventName = ["REMOVE"] })
    }
  }
}

# ─────────────────────────────────────────────
# EVENTBRIDGE — Custom event bus
# ─────────────────────────────────────────────

resource "aws_cloudwatch_event_bus" "main" {
  name = "${local.prefix}-events"
  tags = { Name = "${local.prefix}-events" }
}

# Scheduled cleanup rule (fallback, every 5 minutes)
resource "aws_cloudwatch_event_rule" "cleanup_schedule" {
  name                = "${local.prefix}-cleanup-schedule"
  description         = "Fallback cleanup for stale reservations"
  schedule_expression = "rate(5 minutes)"
  tags                = { Name = "${local.prefix}-cleanup-schedule" }
}

resource "aws_cloudwatch_event_target" "cleanup_schedule" {
  rule      = aws_cloudwatch_event_rule.cleanup_schedule.name
  target_id = "cleanup-lambda"
  arn       = aws_lambda_function.cleanup.arn
}

resource "aws_lambda_permission" "cleanup_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cleanup.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.cleanup_schedule.arn
}

# ─────────────────────────────────────────────
# COGNITO — User Pool for JWT auth
# ─────────────────────────────────────────────

resource "aws_cognito_user_pool" "main" {
  name = "${local.prefix}-users"

  password_policy {
    minimum_length    = 8
    require_uppercase = true
    require_numbers   = true
    require_symbols   = false
  }

  auto_verified_attributes = ["email"]

  tags = { Name = "${local.prefix}-users" }
}

resource "aws_cognito_user_pool_client" "main" {
  name         = "${local.prefix}-client"
  user_pool_id = aws_cognito_user_pool.main.id

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH"
  ]

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30
}

# ─────────────────────────────────────────────
# API GATEWAY — REST API
# ─────────────────────────────────────────────

resource "aws_api_gateway_rest_api" "main" {
  name        = "${local.prefix}-api"
  description = "Zero-Ops Ticket Platform API"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = { Name = "${local.prefix}-api" }
}

resource "aws_api_gateway_authorizer" "cognito" {
  name            = "cognito-authorizer"
  rest_api_id     = aws_api_gateway_rest_api.main.id
  type            = "COGNITO_USER_POOLS"
  identity_source = "method.request.header.Authorization"
  provider_arns   = [aws_cognito_user_pool.main.arn]
}

# /purchase resource
resource "aws_api_gateway_resource" "purchase" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "purchase"
}

resource "aws_api_gateway_method" "purchase_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.purchase.id
  http_method   = "POST"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}

resource "aws_api_gateway_integration" "purchase" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.purchase.id
  http_method             = aws_api_gateway_method.purchase_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.purchase.invoke_arn
}

resource "aws_lambda_permission" "api_gateway_purchase" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.purchase.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.main.execution_arn}/*/*"
}

resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  depends_on  = [aws_api_gateway_integration.purchase]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "main" {
  deployment_id = aws_api_gateway_deployment.main.id
  rest_api_id   = aws_api_gateway_rest_api.main.id
  stage_name    = var.environment

  tags = { Name = "${local.prefix}-stage" }
}

# ─────────────────────────────────────────────
# WAF — Web Application Firewall (us-east-1 for CloudFront)
# ─────────────────────────────────────────────

resource "aws_wafv2_web_acl" "main" {
  provider    = aws.us_east_1
  name        = "${local.prefix}-waf"
  description = "WAF rules for ticket platform"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # Rule 1: Rate limit aggressive IPs (bot protection)
  rule {
    name     = "rate-limit-aggressive"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitAggressive"
      sampled_requests_enabled   = true
    }
  }

  # Rule 2: AWS Managed Rules — Common Rule Set
  rule {
    name     = "aws-managed-common"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedCommon"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.prefix}-waf"
    sampled_requests_enabled   = true
  }

  tags = { Name = "${local.prefix}-waf" }
}

# ─────────────────────────────────────────────
# CLOUDFRONT — CDN + WAF attachment
# ─────────────────────────────────────────────

resource "aws_cloudfront_distribution" "main" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "${local.prefix} CDN"
  web_acl_id      = aws_wafv2_web_acl.main.arn

  origin {
    domain_name = "${aws_api_gateway_rest_api.main.id}.execute-api.${var.aws_region}.amazonaws.com"
    origin_id   = "api-gateway"
    origin_path = "/${var.environment}"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "api-gateway"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = true
      headers      = ["Authorization", "Content-Type"]
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0  # No caching for API responses
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = { Name = "${local.prefix}-cdn" }
}
