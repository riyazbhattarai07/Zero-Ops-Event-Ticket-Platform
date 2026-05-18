# ============================================================
# main.tf — Entry-Level Ticket Platform Infrastructure
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
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = "ca-central-1" # Keeping everything clean in our local region
}

# ============================================================
# 1. ZIP THE PYTHON LAMBDA FILES
# ============================================================
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

# ============================================================
# 2. THE DATABASE (DYNAMODB)
# ============================================================
resource "aws_dynamodb_table" "tickets" {
  name         = "intern-ticket-table"
  billing_mode = "PAY_PER_REQUEST" # Pay only when we test it (saves money!)
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
}

# ============================================================
# 3. THE WAITING LINE (SQS QUEUE)
# ============================================================
resource "aws_sqs_queue" "payment_queue" {
  name                        = "intern-payment-queue.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
}

# ============================================================
# 4. BASIC SECURITY PERMISSIONS (IAM ROLES)
# ============================================================
resource "aws_iam_role" "lambda_role" {
  name = "intern-lambda-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# Simple policy giving our Lambdas permission to talk to DynamoDB, SQS, and CloudWatch logs
resource "aws_iam_role_policy" "lambda_policy" {
  name = "intern-lambda-core-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem"]
        Resource = aws_dynamodb_table.tickets.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
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

# ============================================================
# 5. THE BACKEND FUNCTIONS (AWS LAMBDA)
# ============================================================
resource "aws_lambda_function" "purchase" {
  function_name = "intern-purchase-function"
  role          = aws_iam_role.lambda_role.arn
  runtime       = "python3.12"
  handler       = "purchase.lambda_handler"
  filename      = data.archive_file.purchase.output_path

  environment {
    variables = {
      DYNAMODB_TABLE = aws_dynamodb_table.tickets.name
      SQS_QUEUE_URL  = aws_sqs_queue.payment_queue.url
    }
  }
}

resource "aws_lambda_function" "payment" {
  function_name = "intern-payment-function"
  role          = aws_iam_role.lambda_role.arn
  runtime       = "python3.12"
  handler       = "payment.lambda_handler"
  filename      = data.archive_file.payment.output_path

  environment {
    variables = {
      DYNAMODB_TABLE = aws_dynamodb_table.tickets.name
    }
  }
}

resource "aws_lambda_function" "cleanup" {
  function_name = "intern-cleanup-function"
  role          = aws_iam_role.lambda_role.arn
  runtime       = "python3.12"
  handler       = "cleanup.lambda_handler"
  filename      = data.archive_file.cleanup.output_path

  environment {
    variables = {
      DYNAMODB_TABLE = aws_dynamodb_table.tickets.name
    }
  }
}

# Connect SQS directly to our Payment Lambda
resource "aws_lambda_event_source_mapping" "payment_sqs" {
  event_source_arn = aws_sqs_queue.payment_queue.arn
  function_name    = aws_lambda_function.payment.arn
  batch_size       = 10
  enabled          = true
}

# ============================================================
# 6. THE PUBLIC ENTRY POINT (API GATEWAY)
# ============================================================
resource "aws_api_gateway_rest_api" "main" {
  name        = "intern-ticket-api"
  description = "Simple REST API endpoint for booking tickets"
}

resource "aws_api_gateway_resource" "purchase" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "purchase"
}

resource "aws_api_gateway_method" "purchase_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.purchase.id
  http_method   = "POST"
  authorization = "NONE" # Removed complex Cognito token authorization for a straightforward endpoint
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
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.purchase.function_name
  principal     = "apigateway.amazonaws.com"
}

resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  depends_on  = [aws_api_gateway_integration.purchase]
}

resource "aws_api_gateway_stage" "main" {
  deployment_id = aws_api_gateway_deployment.main.id
  rest_api_id   = aws_api_gateway_rest_api.main.id
  stage_name    = "dev"
}
