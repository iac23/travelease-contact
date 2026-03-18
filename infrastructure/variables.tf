variable "business_email" {
    description = "TravelEase business email for notifications"
    default     = "iacbekker23@gmail.com"
}

variable "dynamodb_table" {
    description = "Database for customer query information"
    default     = "value"
}

variable "aws_region" {
    description = "AWS region for resources"
    type        = string
    default     = "us-east-1"
}
