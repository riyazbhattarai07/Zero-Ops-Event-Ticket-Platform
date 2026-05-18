output "api_endpoint" {
  description = "API Gateway invoke URL"
  value       = "${aws_api_gateway_stage.main.invoke_url}"
}

output "api_id" {
  description = "API Gateway REST API ID"
  value       = aws_api_gateway_rest_api.main.id
}

output "dynamodb_table_name" {
  description = "DynamoDB table name"
  value       = aws_dynamodb_table.tickets.name
}

output "dynamodb_table_arn" {
  description = "DynamoDB table ARN"
  value       = aws_dynamodb_table.tickets.arn
}

output "sqs_queue_url" {
  description = "SQS FIFO queue URL for payment processing"
  value       = aws_sqs_queue.payment_queue.url
}

output "sqs_queue_arn" {
  description = "SQS FIFO queue ARN"
  value       = aws_sqs_queue.payment_queue.arn
}

output "sqs_dlq_url" {
  description = "SQS Dead Letter Queue URL"
  value       = aws_sqs_queue.payment_dlq.url
}

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID for JWT authentication"
  value       = aws_cognito_user_pool.main.id
}

output "cognito_client_id" {
  description = "Cognito App Client ID for frontend/CLI auth"
  value       = aws_cognito_user_pool_client.main.id
  sensitive   = true
}

output "cloudfront_domain" {
  description = "CloudFront distribution domain name"
  value       = aws_cloudfront_distribution.main.domain_name
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID (for cache invalidation)"
  value       = aws_cloudfront_distribution.main.id
}

output "event_bus_name" {
  description = "EventBridge custom event bus name"
  value       = aws_cloudwatch_event_bus.main.name
}

output "purchase_lambda_arn" {
  description = "Purchase Lambda function ARN"
  value       = aws_lambda_function.purchase.arn
}

output "payment_lambda_arn" {
  description = "Payment processor Lambda function ARN"
  value       = aws_lambda_function.payment.arn
}

output "cleanup_lambda_arn" {
  description = "Cleanup Lambda function ARN"
  value       = aws_lambda_function.cleanup.arn
}

output "waf_web_acl_arn" {
  description = "WAF Web ACL ARN (attached to CloudFront)"
  value       = aws_wafv2_web_acl.main.arn
}

output "curl_purchase_example" {
  description = "Example curl command to test the purchase endpoint"
  value       = "curl -X POST ${aws_api_gateway_stage.main.invoke_url}/purchase -H 'Content-Type: application/json' -H 'Authorization: Bearer <JWT_TOKEN>' -d '{\"eventId\":\"evt-001\",\"tier\":\"GA\",\"quantity\":2,\"idempotencyKey\":\"test-123\"}'"
}
