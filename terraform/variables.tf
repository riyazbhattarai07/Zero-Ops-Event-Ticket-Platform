# ============================================================
# variables.tf — All the settings you can change
# ============================================================
# Think of this file as a settings panel.
# Instead of hardcoding values like "us-east-1" everywhere,
# we define them here once and reference them throughout main.tf
#
# To change a value, either:
#   1. Edit the 'default' below
#   2. Or pass it at deploy time: terraform apply -var="environment=prod"
#   3. Or use: make deploy ENV=prod
# ============================================================

# Which AWS region to deploy everything in

variable "aws_region" {
  description = "AWS region to deploy resources (e.g. us-east-1, ca-central-1)"
  type        = string
  default     = "us-east-1"
}

# Which environment are we deploying to?
# This gets added to every resource name so dev and prod don't collide
variable "environment" {
  description = "Deployment environment — affects resource names and settings"
  type        = string
  default     = "dev"

  # Only allow these three values — prevents typos like 'prd' or 'production'
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod"
  }
}

# A short name used as a prefix for all AWS resources
# e.g. resource will be named: zero-ops-tickets-dev-lambda
variable "project_name" {
  description = "Short project name used as prefix for all resource names"
  type        = string
  default     = "zero-ops-tickets"
}

# How much memory to give each Lambda function
# More memory = faster execution (Lambda also gives more CPU with more memory)
# 512MB is a good balance of speed vs cost for this workload
variable "lambda_memory_mb" {
  description = "Memory allocated to Lambda functions in MB (more = faster but costs more)"
  type        = number
  default     = 512
}

# Max seconds a Lambda can run before AWS kills it
# Set to 30s — payment API calls shouldn't take longer than that
variable "lambda_timeout_seconds" {
  description = "Max execution time for Lambda functions in seconds"
  type        = number
  default     = 30
}

# DynamoDB pricing mode
# PAY_PER_REQUEST = pay only when requests are made (great for variable/bursty traffic)
# PROVISIONED = pay for reserved capacity (better if traffic is very predictable)
variable "dynamodb_billing_mode" {
  description = "DynamoDB billing: PAY_PER_REQUEST (bursty) or PROVISIONED (steady traffic)"
  type        = string
  default     = "PAY_PER_REQUEST"
}

# How long SQS hides a message while Lambda is processing it
# Must be >= lambda_timeout_seconds to prevent double-processing
variable "sqs_visibility_timeout" {
  description = "Seconds SQS hides a message while being processed (must be >= Lambda timeout)"
  type        = number
  default     = 60
}

# How long we hold a ticket reservation before releasing it
# 10 minutes gives users enough time to fill in payment details
variable "reservation_ttl_minutes" {
  description = "Minutes to hold a ticket reservation before releasing it back to inventory"
  type        = number
  default     = 10
}

# WAF rate limiting: block IPs that send too many requests
# 100 requests per 5-minute window = normal user
# Bots typically send 1000+ — this blocks them
variable "waf_rate_limit" {
  description = "Max requests per IP per 5-minute window before WAF blocks the IP"
  type        = number
  default     = 100
}

# The email address that sends purchase confirmation emails
# Must be verified in AWS SES first!
variable "ses_sender_email" {
  description = "Verified SES email address for sending purchase confirmations"
  type        = string
  default     = "noreply@example.com"
}

# Tags applied to every AWS resource — useful for cost tracking and organization
variable "tags" {
  description = "Tags added to every AWS resource (for billing and organization)"
  type        = map(string)
  default = {
    Project   = "ZeroOpsTickets"
    ManagedBy = "Terraform"
    Owner     = "riyazbhattarai07"
  }
}
