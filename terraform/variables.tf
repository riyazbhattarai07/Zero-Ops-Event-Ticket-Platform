variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "zero-ops-tickets"
}

variable "lambda_memory_mb" {
  description = "Lambda function memory in MB"
  type        = number
  default     = 512
}

variable "lambda_timeout_seconds" {
  description = "Lambda function timeout in seconds"
  type        = number
  default     = 30
}

variable "dynamodb_billing_mode" {
  description = "DynamoDB billing mode (PAY_PER_REQUEST or PROVISIONED)"
  type        = string
  default     = "PAY_PER_REQUEST"
}

variable "sqs_visibility_timeout" {
  description = "SQS message visibility timeout in seconds (must be >= Lambda timeout)"
  type        = number
  default     = 60
}

variable "reservation_ttl_minutes" {
  description = "How long (minutes) a ticket reservation is held before expiry"
  type        = number
  default     = 10
}

variable "waf_rate_limit" {
  description = "Max requests per IP per 5-minute window before WAF blocks"
  type        = number
  default     = 100
}

variable "ses_sender_email" {
  description = "Verified SES sender email address for purchase confirmations"
  type        = string
  default     = "noreply@example.com"
}

variable "tags" {
  description = "Common resource tags"
  type        = map(string)
  default = {
    Project     = "ZeroOpsTickets"
    ManagedBy   = "Terraform"
    Owner       = "riyazbhattarai07"
  }
}
