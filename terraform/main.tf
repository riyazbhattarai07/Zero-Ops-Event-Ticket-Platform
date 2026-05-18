# ============================================================
# main.tf — The entire AWS infrastructure in one file
# ============================================================
# This file tells Terraform exactly what to build on AWS.
# When you run 'terraform apply', it reads this and creates
# all the cloud resources automatically.
#
# What gets created (in order):
#   1. DynamoDB table      — our database for tickets + reservations
#   2. SQS queues          — the payment queue + a dead letter queue
#   3. IAM roles           — permissions for each Lambda function
#   4. Lambda functions    — purchase.py, payment.py, cleanup.py
#   5. Event mappings      — connect SQS → payment Lambda, DynamoDB stream → cleanup Lambda
#   6. EventBridge         — event bus + scheduled cleanup rule
#   7. Cognito             — user login and JWT token issuing
#   8. API Gateway         — the public REST API with Cognito auth
#   9. WAF                 — rate limiting and bot blocking
#  10. CloudFront          — CDN that sits in front of everything
# ============================================================

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"  # Used to zip up our Lambda Python files
    }
  }
}

# Default AWS provider — uses the region from variables.tf
provider "aws" {
  region = var.aws_region
  default_tags {
    tags = var.tags  # Automatically tag every resource with our project tags
  }
}

# Second provider locked to us-east-1
# WAF for CloudFront MUST be created in us-east-1 regardless of your main region
# This is an AWS requirement, not our choice
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  default_tags {
    tags = var.tags
  }
}

# A shorthand prefix used in every resource name
# Example: "zero-ops-tickets-dev" or "zero-ops-tickets-prod"
locals {
  prefix = "${var.project_name}-${var.environment}"
}


# ============================================================
# 0. PACKAGE LAMBDA FUNCTIONS
# ============================================================
# Terraform needs the Python files as .zip archives to upload to AWS
# The 'archive' provider does this automatically before deploying

data "archive_file" "purchase" {
  type        = "zip"
  source_file = "${path.module}/../lambda/purchase.py"    # Where the source file is
  output_path = "${path.module}/../.build/purchase.zip"   # Where to put the zip
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


# ============================================================
# 1. DYNAMODB — Our database
# ============================================================
# Stores two types of data:
#   a) Inventory records  — EventID + Tier → how many tickets are available
#   b) Reservation records — tracks each user's held tickets (with 10-min TTL)
#
# Why DynamoDB instead of a regular database (MySQL/Postgres)?
#   - Scales to 10,000+ writes/second automatically (no tuning needed)
#   - No server to manage or patch
#   - Built-in TTL (auto-deletes expired records)
#   - Streams let us react instantly to deletions (for cleanup.py)

resource "aws_dynamodb_table" "tickets" {
  name         = "${local.prefix}-tickets"
  billing_mode = var.dynamodb_billing_mode  # PAY_PER_REQUEST = no upfront capacity planning
  hash_key     = "EventID"                  # Partition key (e.g. 'evt-taylor-swift')
  range_key    = "Tier"                     # Sort key (e.g. 'GA', 'VIP', 'FLOOR')

  attribute {
    name = "EventID"
    type = "S"  # S = String
  }

  attribute {
    name = "Tier"
    type = "S"
  }

  # TTL: DynamoDB will auto-delete items once their 'TTL' timestamp is in the past
  # This is how we auto-expire reservations after 10 minutes
  ttl {
    attribute_name = "TTL"  # The field in each item that holds the expiry timestamp
    enabled        = true
  }

  # Streams: When items are deleted (by TTL or manually), send an event to cleanup.py
  # OLD_IMAGE means we get the data of the item that was deleted
  stream_enabled   = true
  stream_view_type = "OLD_IMAGE"

  # Point-in-time recovery: lets you restore the DB to any second in the last 35 days
  point_in_time_recovery {
    enabled = true
  }

  # Encrypt data at rest using AWS-managed KMS key (free, no setup needed)
  server_side_encryption {
    enabled = true
  }

  tags = { Name = "${local.prefix}-tickets" }
}


# ============================================================
# 2. SQS — Message queue for payment processing
# ============================================================
# Think of SQS as a to-do list in the cloud.
# purchase.py adds jobs to the list, payment.py picks them up.
#
# Why FIFO (First-In-First-Out)?
#   - Guarantees messages are processed in order per event
#   - Prevents the same message from being processed twice (deduplication)
#
# Dead Letter Queue (DLQ):
#   - If payment.py fails to process a message 3 times, the message
#     moves to the DLQ automatically instead of being lost forever

# The DLQ — holds failed messages for 14 days so you can inspect them
resource "aws_sqs_queue" "payment_dlq" {
  name                        = "${local.prefix}-payment-dlq.fifo"  # .fifo suffix required for FIFO queues
  fifo_queue                  = true
  content_based_deduplication = true
  message_retention_seconds   = 1209600  # 14 days (max allowed by SQS)
  tags                        = { Name = "${local.prefix}-payment-dlq" }
}

# The main payment queue
resource "aws_sqs_queue" "payment_queue" {
  name                        = "${local.prefix}-payment.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  visibility_timeout_seconds  = var.sqs_visibility_timeout  # Hide message while Lambda processes it
  message_retention_seconds   = 86400                       # Keep messages for 24 hours

  # After 3 failed processing attempts, move the message to the DLQ
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.payment_dlq.arn
    maxReceiveCount     = 3
  })

  tags = { Name = "${local.prefix}-payment-queue" }
}


# ============================================================
# 3. IAM — Permissions for each Lambda function
# ============================================================
# By default, Lambda functions have zero AWS permissions.
# We follow the "least privilege" principle:
# each function only gets access to exactly what it needs.
#
# purchase Lambda  → read/write DynamoDB + send to SQS
# payment Lambda   → read/write DynamoDB + receive from SQS + write EventBridge
# cleanup Lambda   → read/write/delete DynamoDB + read DynamoDB stream + write EventBridge

# This policy lets Lambda assume (use) these IAM roles
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# --- Purchase Lambda role ---
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
        # Can read and write to DynamoDB (for inventory + reservations)
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.tickets.arn
      },
      {
        # Can send messages to the payment queue
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.payment_queue.arn
      },
      {
        # Can write logs to CloudWatch (needed for debugging)
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# --- Payment Lambda role ---
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
        # Can receive and delete messages from SQS (processing + acknowledging)
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.payment_queue.arn
      },
      {
        # Can publish events to EventBridge (to trigger email, analytics, etc.)
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

# --- Cleanup Lambda role ---
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
        # Needs full DynamoDB access + stream access to watch for TTL expirations
        Effect = "Allow"
        Action = [
          "dynamodb:Scan", "dynamodb:UpdateItem", "dynamodb:DeleteItem",
          "dynamodb:GetRecords", "dynamodb:GetShardIterator",
          "dynamodb:DescribeStream", "dynamodb:ListStreams"
        ]
        Resource = [
          aws_dynamodb_table.tickets.arn,
          "${aws_dynamodb_table.tickets.arn}/stream/*"  # The stream is a separate ARN
        ]
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


# ============================================================
# 4. LAMBDA FUNCTIONS
# ============================================================
# Three functions, each handling one stage of the ticket purchase flow

# purchase.py — handles incoming purchase requests
resource "aws_lambda_function" "purchase" {
  function_name    = "${local.prefix}-purchase"
  role             = aws_iam_role.purchase_lambda.arn
  runtime          = "python3.12"                                       # Python version
  handler          = "purchase.lambda_handler"                          # file.function_name
  filename         = data.archive_file.purchase.output_path             # The zip file to upload
  source_code_hash = data.archive_file.purchase.output_base64sha256     # Triggers redeploy when code changes
  memory_size      = var.lambda_memory_mb
  timeout          = var.lambda_timeout_seconds

  # These become os.environ variables inside purchase.py
  environment {
    variables = {
      DYNAMODB_TABLE = aws_dynamodb_table.tickets.name
      SQS_QUEUE_URL  = aws_sqs_queue.payment_queue.url
      ENVIRONMENT    = var.environment
    }
  }

  tags = { Name = "${local.prefix}-purchase" }
}

# payment.py — processes payments from the SQS queue
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

# cleanup.py — returns tickets from expired reservations
resource "aws_lambda_function" "cleanup" {
  function_name    = "${local.prefix}-cleanup"
  role             = aws_iam_role.cleanup_lambda.arn
  runtime          = "python3.12"
  handler          = "cleanup.lambda_handler"
  filename         = data.archive_file.cleanup.output_path
  source_code_hash = data.archive_file.cleanup.output_base64sha256
  memory_size      = 256    # Cleanup doesn't need as much memory as purchase/payment
  timeout          = 60     # Scheduled scans can take a bit longer

  environment {
    variables = {
      DYNAMODB_TABLE = aws_dynamodb_table.tickets.name
      EVENT_BUS_NAME = aws_cloudwatch_event_bus.main.name
      ENVIRONMENT    = var.environment
    }
  }

  tags = { Name = "${local.prefix}-cleanup" }
}


# ============================================================
# 5. EVENT SOURCE MAPPINGS — What triggers each Lambda
# ============================================================

# SQS → payment Lambda
# When there are messages in the queue, AWS automatically triggers payment.py
# with a batch of up to 10 messages at once
resource "aws_lambda_event_source_mapping" "payment_sqs" {
  event_source_arn = aws_sqs_queue.payment_queue.arn
  function_name    = aws_lambda_function.payment.arn
  batch_size       = 10    # Process up to 10 payments at once
  enabled          = true
}

# DynamoDB Stream → cleanup Lambda
# When DynamoDB TTL deletes an expired reservation, this fires cleanup.py
resource "aws_lambda_event_source_mapping" "cleanup_stream" {
  event_source_arn  = aws_dynamodb_table.tickets.stream_arn
  function_name     = aws_lambda_function.cleanup.arn
  starting_position = "LATEST"   # Only process new events (not old history)
  batch_size        = 100        # Handle up to 100 deletions at once
  enabled           = true

  # Only trigger on REMOVE events (TTL deletions) — ignore INSERT and MODIFY
  filter_criteria {
    filter {
      pattern = jsonencode({ eventName = ["REMOVE"] })
    }
  }
}


# ============================================================
# 6. EVENTBRIDGE — Event bus + scheduled cleanup
# ============================================================
# EventBridge is like a pub/sub system.
# Our Lambdas publish events (e.g. "ticket.purchased"),
# and other services can subscribe to be notified automatically.
# This keeps services loosely coupled — they don't call each other directly.

# Our custom event bus (separate from the default AWS bus)
resource "aws_cloudwatch_event_bus" "main" {
  name = "${local.prefix}-events"
  tags = { Name = "${local.prefix}-events" }
}

# Scheduled rule: run cleanup.py every 5 minutes as a safety net
resource "aws_cloudwatch_event_rule" "cleanup_schedule" {
  name                = "${local.prefix}-cleanup-schedule"
  description         = "Fallback: scan for stale reservations TTL may have missed"
  schedule_expression = "rate(5 minutes)"
  tags                = { Name = "${local.prefix}-cleanup-schedule" }
}

# Point the schedule at the cleanup Lambda
resource "aws_cloudwatch_event_target" "cleanup_schedule" {
  rule      = aws_cloudwatch_event_rule.cleanup_schedule.name
  target_id = "cleanup-lambda"
  arn       = aws_lambda_function.cleanup.arn
}

# Allow EventBridge to actually invoke the Lambda (Lambda needs explicit permission)
resource "aws_lambda_permission" "cleanup_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cleanup.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.cleanup_schedule.arn
}


# ============================================================
# 7. COGNITO — User authentication
# ============================================================
# Cognito handles user accounts and login.
# After logging in, users get a JWT token.
# They include this token in every API request.
# API Gateway validates the token before letting requests through.
# This means our Lambda functions never have to check passwords.

resource "aws_cognito_user_pool" "main" {
  name = "${local.prefix}-users"

  password_policy {
    minimum_length    = 8
    require_uppercase = true
    require_numbers   = true
    require_symbols   = false  # Symbols optional — keeps it user-friendly
  }

  # Send a verification email when users sign up
  auto_verified_attributes = ["email"]

  tags = { Name = "${local.prefix}-users" }
}

# The "App Client" — represents our application connecting to the user pool
resource "aws_cognito_user_pool_client" "main" {
  name         = "${local.prefix}-client"
  user_pool_id = aws_cognito_user_pool.main.id

  # Allow username+password login and refresh tokens
  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH"
  ]

  # Token expiry settings
  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  access_token_validity  = 1   # Access token expires after 1 hour
  id_token_validity      = 1
  refresh_token_validity = 30  # Refresh token lasts 30 days
}


# ============================================================
# 8. API GATEWAY — The public REST API
# ============================================================
# API Gateway is the front door of our application.
# It receives HTTP requests, validates the JWT token via Cognito,
# then forwards the request to the right Lambda function.
#
# Route: POST /purchase → purchase Lambda

resource "aws_api_gateway_rest_api" "main" {
  name        = "${local.prefix}-api"
  description = "Zero-Ops Ticket Platform REST API"

  endpoint_configuration {
    types = ["REGIONAL"]  # Deployed in one region (vs EDGE which uses CloudFront)
  }

  tags = { Name = "${local.prefix}-api" }
}

# Cognito authorizer — validates JWT tokens on every request
# If the token is missing or expired, API Gateway returns 401 automatically
resource "aws_api_gateway_authorizer" "cognito" {
  name            = "cognito-authorizer"
  rest_api_id     = aws_api_gateway_rest_api.main.id
  type            = "COGNITO_USER_POOLS"
  identity_source = "method.request.header.Authorization"  # Look for token in Authorization header
  provider_arns   = [aws_cognito_user_pool.main.arn]
}

# Create the /purchase URL path
resource "aws_api_gateway_resource" "purchase" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "purchase"  # This becomes /purchase in the URL
}

# Accept POST requests to /purchase (and require Cognito auth)
resource "aws_api_gateway_method" "purchase_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.purchase.id
  http_method   = "POST"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}

# Wire POST /purchase to the purchase Lambda (AWS_PROXY = pass everything through)
resource "aws_api_gateway_integration" "purchase" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.purchase.id
  http_method             = aws_api_gateway_method.purchase_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"  # Pass the full request to Lambda as-is
  uri                     = aws_lambda_function.purchase.invoke_arn
}

# Allow API Gateway to invoke the purchase Lambda
resource "aws_lambda_permission" "api_gateway_purchase" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.purchase.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.main.execution_arn}/*/*"
}

# Deploy the API (makes it publicly accessible)
resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  depends_on  = [aws_api_gateway_integration.purchase]  # Wait until routes are set up

  lifecycle {
    create_before_destroy = true  # Zero-downtime redeploys
  }
}

# The stage is the environment name in the URL: /dev, /staging, /prod
resource "aws_api_gateway_stage" "main" {
  deployment_id = aws_api_gateway_deployment.main.id
  rest_api_id   = aws_api_gateway_rest_api.main.id
  stage_name    = var.environment

  tags = { Name = "${local.prefix}-stage" }
}


# ============================================================
# 9. WAF — Bot blocking and rate limiting
# ============================================================
# WAF (Web Application Firewall) sits in front of CloudFront.
# It inspects every incoming request before it reaches our API.
#
# Rule 1: Rate limiting — if an IP sends more than 100 requests in
#         5 minutes, block it. Normal users won't hit this. Bots will.
#
# Rule 2: AWS Managed Rules — AWS maintains a list of known bad actors,
#         exploit patterns, and vulnerability signatures. We get that
#         protection for free just by enabling this rule.
#
# IMPORTANT: WAF for CloudFront MUST be in us-east-1
# That's why we use provider = aws.us_east_1 here

resource "aws_wafv2_web_acl" "main" {
  provider    = aws.us_east_1
  name        = "${local.prefix}-waf"
  description = "Protects against bots, scrapers, and common web attacks"
  scope       = "CLOUDFRONT"  # Must be CLOUDFRONT (not REGIONAL) for use with CloudFront

  # Default: allow all traffic (we'll block specific bad patterns)
  default_action {
    allow {}
  }

  # Rule 1: Block IPs that send too many requests (bot/scraper detection)
  rule {
    name     = "rate-limit-aggressive"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit  # Default: 100 requests per 5 minutes
        aggregate_key_type = "IP"               # Track per IP address
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitAggressive"
      sampled_requests_enabled   = true
    }
  }

  # Rule 2: AWS Managed Rules — common threat intelligence (SQLi, XSS, known bad IPs)
  rule {
    name     = "aws-managed-common"
    priority = 2

    override_action {
      none {}  # Use AWS's default action for each sub-rule
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


# ============================================================
# 10. CLOUDFRONT — CDN sitting in front of everything
# ============================================================
# CloudFront is a Content Delivery Network with 450+ edge locations worldwide.
# Every request goes through CloudFront first, which:
#   - Runs WAF rules (bot blocking, rate limiting)
#   - Enforces HTTPS (redirects HTTP → HTTPS automatically)
#   - Routes to API Gateway
#
# For this API, we disable caching (TTL = 0) because
# every purchase request must reach the Lambda fresh.

resource "aws_cloudfront_distribution" "main" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "${local.prefix} — CDN + WAF for ticket platform"
  web_acl_id      = aws_wafv2_web_acl.main.arn  # Attach our WAF rules

  # Where to forward requests to (our API Gateway)
  origin {
    domain_name = "${aws_api_gateway_rest_api.main.id}.execute-api.${var.aws_region}.amazonaws.com"
    origin_id   = "api-gateway"
    origin_path = "/${var.environment}"  # Adds /dev or /prod to the path

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"        # Only communicate with API Gateway over HTTPS
      origin_ssl_protocols   = ["TLSv1.2"]         # Modern TLS only
    }
  }

  # How to handle requests to this distribution
  default_cache_behavior {
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "api-gateway"
    viewer_protocol_policy = "redirect-to-https"   # Force HTTPS

    forwarded_values {
      query_string = true
      headers      = ["Authorization", "Content-Type"]  # Pass auth headers through to Lambda
      cookies {
        forward = "none"
      }
    }

    # Disable caching for all API responses (tickets change in real-time)
    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"  # Allow traffic from all countries
    }
  }

  # Use the default CloudFront certificate (free, works with *.cloudfront.net domains)
  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = { Name = "${local.prefix}-cdn" }
}
