variable "business_email" {
    description = "TravelEase business email for notifications"
    type        = string
}

variable "dynamodb_table" {
    description = "Database for customer query information"
    type        = string
}

variable "aws_region" {
    description = "AWS region for resources"
    type        = string
    default     = "us-east-1"
}
