# ============================================================
# outputs.tf — Values printed after 'terraform apply'
# ============================================================
# After Terraform finishes deploying, it prints these values.
# They're useful for:
#   - Finding your API URL to test with curl
#   - Getting IDs needed to configure the frontend
#   - Feeding values into other scripts (like load tests)
#
# You can also retrieve any output any time with:
#   terraform output <output_name>
#   terraform output -json   (to get all outputs as JSON)
# ============================================================

# The public URL your API is accessible at
# This is what you paste into curl or your frontend

output "api_endpoint" {
  description = "Your API Gateway URL — use this to make requests"
  value       = "${aws_api_gateway_stage.main.invoke_url}"
}

output "api_id" {
  description = "API Gateway REST API ID (useful for debugging in AWS console)"
  value       = aws_api_gateway_rest_api.main.id
}

# DynamoDB table info
output "dynamodb_table_name" {
  description = "Name of the DynamoDB table storing tickets and reservations"
  value       = aws_dynamodb_table.tickets.name
}

output "dynamodb_table_arn" {
  description = "DynamoDB table ARN (Amazon Resource Name — the unique identifier)"
  value       = aws_dynamodb_table.tickets.arn
}

# SQS Queue info
output "sqs_queue_url" {
  description = "SQS payment queue URL — used by purchase.py to send messages"
  value       = aws_sqs_queue.payment_queue.url
}

output "sqs_queue_arn" {
  description = "SQS payment queue ARN"
  value       = aws_sqs_queue.payment_queue.arn
}

output "sqs_dlq_url" {
  description = "Dead Letter Queue URL — failed messages land here after 3 retries"
  value       = aws_sqs_queue.payment_dlq.url
}

# Cognito — needed to log in and get a JWT token for testing
output "cognito_user_pool_id" {
  description = "Cognito User Pool ID — needed for AWS CLI login commands"
  value       = aws_cognito_user_pool.main.id
}

output "cognito_client_id" {
  description = "Cognito App Client ID — needed for AWS CLI login commands"
  value       = aws_cognito_user_pool_client.main.id
  sensitive   = true   # Marked sensitive so it doesn't show in plain text logs
}

# CloudFront CDN
output "cloudfront_domain" {
  description = "CloudFront domain — this is the public-facing URL with WAF protection"
  value       = aws_cloudfront_distribution.main.domain_name
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID — used to invalidate cache after deploys"
  value       = aws_cloudfront_distribution.main.id
}

# EventBridge
output "event_bus_name" {
  description = "EventBridge custom event bus name — used by Lambdas to publish events"
  value       = aws_cloudwatch_event_bus.main.name
}

# Lambda ARNs (useful for setting up monitoring or extra permissions)
output "purchase_lambda_arn" {
  description = "ARN of the Purchase Lambda function"
  value       = aws_lambda_function.purchase.arn
}

output "payment_lambda_arn" {
  description = "ARN of the Payment Processor Lambda function"
  value       = aws_lambda_function.payment.arn
}

output "cleanup_lambda_arn" {

  description = "ARN of the Cleanup Lambda function"
  value       = aws_lambda_function.cleanup.arn
}

# WAF
output "waf_web_acl_arn" {
  description = "WAF Web ACL ARN — attached to CloudFront to block bots and rate-limit IPs"
  value       = aws_wafv2_web_acl.main.arn
}

# Ready-to-use curl command for testing
# Just replace <JWT_TOKEN> with a real token from Cognito
output "curl_purchase_example" {
  description = "Copy-paste curl command to test the purchase endpoint"
  value       = "curl -X POST ${aws_api_gateway_stage.main.invoke_url}/purchase -H 'Content-Type: application/json' -H 'Authorization: Bearer <JWT_TOKEN>' -d '{\"eventId\":\"evt-001\",\"tier\":\"GA\",\"quantity\":2,\"idempotencyKey\":\"test-123\"}'"
}
