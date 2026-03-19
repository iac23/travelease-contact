terraform {
    required_providers {
        aws = {
            source = "hashicorp/aws"
            version = "= 6.23.0"
        }
        archive = {
          source = "hashicorp/archive"
          version = "= 2.7.1"
        }
    }
    required_version = ">= 1.14.0"
}

provider "aws" {
    region = "us-east-1"
}

# Bucket for website hosting

resource "aws_s3_bucket" "my-bucket" {
    bucket = "travelease-web-bucket"

    tags = {
        Name = "My Bucket"
        Environment = "Production"
    }
}

# Configures website hosting 

resource "aws_s3_bucket_website_configuration" "my-bucket" {    # name of the resource + unique name of resource
    
    bucket = aws_s3_bucket.my-bucket.id

    index_document {
      suffix = "index.html"
    }

    error_document {
        key = "error.html"
    }

}

# Allow public access

resource "aws_s3_bucket_public_access_block" "public-policy-settings" {
  bucket = aws_s3_bucket.my-bucket.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false       # For static hosting ALL should be FALSE
}

# Bucket Policy for S3 static website

resource "aws_s3_bucket_policy" "allow-public-access" {
  bucket = aws_s3_bucket.my-bucket.id
  policy = data.aws_iam_policy_document.s3-public-read-policy.json  # Resource policy name should match data block line 59

  depends_on = [aws_s3_bucket_public_access_block.public-policy-settings] # creates resource dependency
}

data "aws_iam_policy_document" "s3-public-read-policy" {    # Name should match the policy document on line 56
  statement {
    principals {
      type        = "AWS"
      identifiers = ["*"]       # This allows anonymous public users access to bucket
    }

    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]

    resources = [
      aws_s3_bucket.my-bucket.arn,
      "${aws_s3_bucket.my-bucket.arn}/*",       # List the exact resource you are allowing users to access
    ]
  }
}

# CloudFront distribution for S3 static website
resource "aws_cloudfront_distribution" "website_distribution" {
  enabled = true
  default_root_object = "index.html"

  origin {
    domain_name = replace(aws_s3_bucket_website_configuration.my-bucket.website_endpoint, "http://", "")
    origin_id = "S3-Website"

    custom_origin_config {    # because S3 website endpoint, NOT s3 bucket origin
      http_port = 80
      https_port = 443
      origin_protocol_policy = "http-only"  # s3 static website only serves HTTP
      origin_ssl_protocols = ["TLSv1.2"]
      
    }
  }

  default_cache_behavior {
    allowed_methods = ["GET", "HEAD"]
    cached_methods = ["GET", "HEAD"]
    target_origin_id = "S3-Website"
    viewer_protocol_policy = "redirect-to-https"    # Users will get HTTPS!

    forwarded_values {
      query_string = false 
      cookies {
        forward = "none"
      }
    }

    min_ttl = 0
    default_ttl = 3600
    max_ttl = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
      }
    }

    viewer_certificate {
      cloudfront_default_certificate = true # free HTTPS by using cloudfront default cert
    }
  }


# API Key for API Gateway
resource "aws_api_gateway_api_key" "frontend_key" {
  name = "travelease-frontend-key"
  enabled = true
}

# Usage plan for API key
resource "aws_api_gateway_usage_plan" "basic_plan" {
  name = "travelease-basic-plan"

  api_stages {
    api_id = aws_api_gateway_rest_api.travelease_api.id
    stage = aws_api_gateway_stage.production.stage_name
  }

  throttle_settings {   // limit per API key
    burst_limit = 100
    rate_limit  = 50
  }
}

# Associate API key with the usage plan
resource "aws_api_gateway_usage_plan_key" "main" {
  key_id = aws_api_gateway_api_key.frontend_key.id
  key_type = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.basic_plan.id
}

# 1) REST API

resource "aws_api_gateway_rest_api" "travelease_api" {   # REST API first 
  name        = "MyAPI"
  description = "This is my API for portfolio project purposes"
}

# 2) API Gateway resource (path)

resource "aws_api_gateway_resource" "submit_resource" {   # API Gateway resource second
  rest_api_id = aws_api_gateway_rest_api.travelease_api.id
  parent_id   = aws_api_gateway_rest_api.travelease_api.root_resource_id
  path_part   = "submit"  # The submit endpoint
}

# 3.1) HTTP Method 1: Handle CORS preflight check

resource "aws_api_gateway_method" "options_method" {
  rest_api_id   = aws_api_gateway_rest_api.travelease_api.id
  resource_id   = aws_api_gateway_resource.submit_resource.id
  http_method   = "OPTIONS"   # Required for CORS preflight
  authorization = "NONE"
}

# 3.2) HTTP Method 2: Handle form submissions

resource "aws_api_gateway_method" "post_method" {
  rest_api_id   = aws_api_gateway_rest_api.travelease_api.id
  resource_id   = aws_api_gateway_resource.submit_resource.id
  http_method   = "POST"   # For form submissions
  authorization = "NONE"
  api_key_required = true
}

# 4.1) CORS HTTPS Method Integration // Method 1 + Integration

resource "aws_api_gateway_integration" "cors_integration" {
  rest_api_id          = aws_api_gateway_rest_api.travelease_api.id
  resource_id          = aws_api_gateway_resource.submit_resource.id
  http_method          = aws_api_gateway_method.options_method.http_method
  type                 = "MOCK"
  
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

# 4.2) Lambda HTTP Method Integration // Method 2 + Integration

resource "aws_api_gateway_integration" "lambda_integration" {
  rest_api_id             = aws_api_gateway_rest_api.travelease_api.id
  resource_id             = aws_api_gateway_resource.submit_resource.id
  http_method             = aws_api_gateway_method.post_method.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"   # Lambda proxy integration
  uri                     = aws_lambda_function.travelease_lambda.invoke_arn    # URI = Uniform resource identifier
}

# 5.1) CORS (options) Method response configuration

resource "aws_api_gateway_method_response" "options_200" {
  rest_api_id = aws_api_gateway_rest_api.travelease_api.id
  resource_id = aws_api_gateway_resource.submit_resource.id
  http_method = aws_api_gateway_method.options_method.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true  # Which custom headers can be sent
    "method.response.header.Access-Control-Allow-Methods" = true  # HTTP methods that are allowed
    "method.response.header.Access-Control-Allow-Origin"  = true  # Which domain can call this API
  }
}

# 5.2) CORS (options) Integration response

resource "aws_api_gateway_integration_response" "options_integration_response" {
  rest_api_id = aws_api_gateway_rest_api.travelease_api.id
  resource_id = aws_api_gateway_resource.submit_resource.id
  http_method = aws_api_gateway_method.options_method.http_method
  status_code = aws_api_gateway_method_response.options_200.status_code

  response_parameters = { # The response parameters here need actual values

    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin" = "'*'" # Placeholder for specific S3 domain
  }
}

# 5.3) Lambda (post) Method response

resource "aws_api_gateway_method_response" "post_response" {
  rest_api_id = aws_api_gateway_rest_api.travelease_api.id
  resource_id = aws_api_gateway_resource.submit_resource.id
  http_method = aws_api_gateway_method.post_method.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = true
  }
}

# 5.4) Lambda (post) Integration response

resource "aws_api_gateway_integration_response" "postint_response" {
  rest_api_id = aws_api_gateway_rest_api.travelease_api.id
  resource_id = aws_api_gateway_resource.submit_resource.id
  http_method = aws_api_gateway_method.post_method.http_method
  status_code = aws_api_gateway_method_response.post_response.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = "'*'"  # Placeholder for S3 domain
  }
}

# Deploy API Gateway (required to test!)
resource "aws_api_gateway_deployment" "api_gateway_deploy" {
  rest_api_id = aws_api_gateway_rest_api.travelease_api.id


  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.submit_resource.id,
      aws_api_gateway_method.post_method.id,
      aws_api_gateway_integration.lambda_integration.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

// Creates a named environment for the DEPLOYMENT

resource "aws_api_gateway_stage" "production" {   // For all endpoint globally
  deployment_id = aws_api_gateway_deployment.api_gateway_deploy.id
  rest_api_id   = aws_api_gateway_rest_api.travelease_api.id
  stage_name    = "prod"
}

// Adding throttling limits to API Gateway Stage
resource "aws_api_gateway_method_settings" "throttle" {
  rest_api_id = aws_api_gateway_rest_api.travelease_api.id
  stage_name = aws_api_gateway_stage.production.stage_name
  method_path = "*/*"   // this applies to ALL methods

  settings {
    throttling_burst_limit = 5000
    throttling_rate_limit = 10000
    
    // Add CloudWatch Logs Role ARN -- adjust settings to enable logging
  }
}

# LAMBDA - IAM Role
resource "aws_iam_role" "lambda_role" {
  name = "travelease_lambda_role"

# IAM Policy for Lambda
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"  # the AWS service assuming the IAM Role
        }
      }
    ]
  })

}

# DynamoDB IAM Policy for Lambda 
resource "aws_iam_policy" "lambda_dynamodb" {
  name = "lambda-dynamodb-access"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:PutItem",
        "dynamodb:GetItem",
        "dyanamodb:Query",
        "dynamodb:UpdateItem"
      ]
      Resource = aws_dynamodb_table.submissions.arn   # Name given to database table resource
    }]
  })
}

# Attach DynamoDB IAM Policy
resource "aws_iam_role_policy_attachment" "ddb_attach" {
  role       = aws_iam_role.lambda_role.name        # expects name not ID
  policy_arn = aws_iam_policy.lambda_dynamodb.arn   # Name given to specific IAM Policy
}

# SES IAM Policy for Lambda Function
resource "aws_iam_policy" "lambda_ses" {
  name = "lambda_ses_integration"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ses:SendEmail",
        "ses:SendRawEmail",
        "ses:GetSendStatistics",
      ]
      Resource = "*"
    }]
  })
}

# Attach SES IAM Policy for Lambda Function
resource "aws_iam_role_policy_attachment" "lambda_ses_attach" {
  role = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_ses.arn
}

# Attach AWS Managed policy for basic Lambda execution
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Secrets Manager Policy for Lambda
resource "aws_iam_policy" "lambda_secrets" {
  name = "lambda-secrets-access"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue"
      ]
      Resource = "arn:aws:secretsmanager:us-east-1:*:secret:travelease/*"
    }]
  })
}
# Attach Secrets Manager Policy
resource "aws_iam_role_policy_attachment" "secrets_attach" {
  role = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_secrets.arn
}


# Permission to allow API to invoke Lambda
resource "aws_lambda_permission" "api_gateway_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.travelease_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.travelease_api.execution_arn}/*/*"
}

 

# LAMBDA Function Resource

# Package the Lambda function code
data "archive_file" "lambda_function_code" {
  type        = "zip"
  source_file = "${path.module}/lambda/index.py"    # Name of lambda file where Python code is written
  output_path = "${path.module}/lambda/function.zip"
}

# Lambda function
resource "aws_lambda_function" "travelease_lambda" {
  filename         = data.archive_file.lambda_function_code.output_path
  function_name    = "travelease_lambda"
  role             = aws_iam_role.lambda_role.arn
  handler          = "index.lambda_handler"
  source_code_hash = data.archive_file.lambda_function_code.output_base64sha256
  timeout          = 60

  runtime = "python3.11"  # Because my Lambda code is Python

# Added env variable secret in backend.yml workflow
# Made changes to email and database variable values

  environment {
    variables = {      // stored in variables.tf
      business_email = var.business_email
      dynamodb_table = var.dynamodb_table
      environment    = "production"
      log_level      = "info"
      SECRET_NAME    = "travelease/claude-api-key"
    }
  }

  tags = {
    Environment = "production"
    Application = "example"
  }
}

# DynamoDB Table Resource

resource "aws_dynamodb_table" "submissions" {
  name         = var.dynamodb_table   # Travelease submissions
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "submission_id"    # Unique ID (Partition Key)
  range_key    = "timestamp"        # This is the sort key for FIFO ordering

  attribute { # 1) Partition Key
    name = "submission_id"
    type = "S"    # string - unique ID name and number
  }

  attribute { # 2) Sort Key
    name = "timestamp"
    type = "N"    # unix timestamp for sorting / DynamoDB table expects a Number
  }

  tags = {
    Name      = "production"
    Project   = "travelease"
  }

# Good additional arguments for Production setup
  point_in_time_recovery {
    enabled = true    # Backup/Restore capability
  }

  server_side_encryption {
    enabled = true    # Encrypt data at rest
  } 
}

# Newly added resources 3/15 pushed to main with correct workflow syntax for backend.yml
# OIDC Config for CI/CD pipeline with Github Actions

resource "aws_iam_openid_connect_provider" "default" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com",
  ]
}

# OIDC audience matches now
# IAM Role for GitHub to assume on specific workflow

resource "aws_iam_role" "github_workflow" {
  name = "github_role"

# IAM Role Assume Policy for GitHub

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRoleWithWebIdentity"
        Effect = "Allow"
        Sid    = "GitHubActionsRole"
        Principal = {       # the principal is a federated identity
          Federated = aws_iam_openid_connect_provider.default.arn
        }
        
        # Updated condition block: Switched to StringLike and subject value ends in wildcard "*"
        Condition = {
          StringLike = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = "repo:iac23/travelease-contact:*"
          }
        }
      },
    ]
  })

  tags = {
    tag-key = "tag-value"
  }
}

# IAM Policy for IAM Role for GitHub Actions - Terraform

resource "aws_iam_policy" "github_oidc_policy" {
  name        = "github-oidc-policy"
  path        = "/"
  description = "OIDC provider GitHub Actions IAM policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {

        # Both state file and static web S3 buckets
        
        Sid = "S3Access"
        Effect   = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketPolicy",
          "s3:GetBucketWebsite",
          "s3:GetBucketCORS",
          "s3:GetBucketVersioning",
          "s3:GetEncryptionConfiguration",
          "s3:GetBucketPublicAccessBlock",
          "s3:GetBucketAcl",
          "s3:GetBucketLogging",
          "s3:GetLifecycleConfiguration",
          "s3:GetReplicationConfiguration",
          "s3:GetAccelerateConfiguration",
          "s3:GetBucketRequestPayment",
          "s3:GetBucketObjectLockConfiguration",
          "s3:GetBucket*"
          
        ]
        Resource = [
          "arn:aws:s3:::travelease-web-bucket",   # S3 needs two resource entries: 1. bucket itself, 2. objects inside bucket
          "arn:aws:s3:::travelease-web-bucket/*",
          "arn:aws:s3:::travelease-tf-state",
          "arn:aws:s3:::travelease-tf-state/*"
        ]
      },      # comma separates by closing one block and starting a new one


      # BACKEND: Lambda Management
      {
        Sid = "LambdaManagement"
        Effect = "Allow"
        Action = [
          "lambda:CreateFunction",
          "lambda:UpdateFunctionCode",
          "lambda:UpdateFunctionConfiguration",
          "lambda:GetFunction",
          "lambda:GetFunctionConfiguration",
          "lambda:AddPermission",
          "lambda:RemovePermission",
          "lambda:GetPolicy",
          "lambda:ListVersionsByFunction",
          "lambda:GetFunctionCodeSigningConfig",
          "lambda:ListAliases",
          "lambda:GetRuntimeManagementConfig"       
        ]
        Resource = [
          "arn:aws:lambda:*:*:function:travelease_*"   # using a wildcard at end of ARN means only Lambda functions that start with travelease
        ]
      },
    
      # BACKEND: API Gateway Management
      {
      Sid    = "APIGatewayManagement"
      Effect = "Allow"
      Action = [
        "apigateway:GET",     # these aren't HTTP methods, they map directly to AWS API Calls TF makes
        "apigateway:POST",
        "apigateway:PUT",
        "apigateway:PATCH",
        "apigateway:DELETE"

      ]
      Resource = [
        "arn:aws:apigateway:us-east-1::/restapis/*",
        "arn:aws:apigateway:us-east-1::/apikeys/*",     
        "arn:aws:apigateway:us-east-1::/usageplans/*" 
                 
      ] 
    },

      # BACKEND: DynamoDB management
    {
      Sid    = "DynamoDBManagement"
      Effect = "Allow"
      Action = [
          "dynamodb:CreateTable",
          "dynamodb:DescribeTable",
          "dynamodb:UpdateTable",
          "dynamodb:DeleteTable",
          "dynamodb:ListTables",
          "dynamodb:DescribeTimeToLive",
          "dynamodb:UpdateTimeToLive",
          "dynamodb:DescribeContinuousBackups",
          "dynamodb:UpdateContinuousBackups",
          "dynamodb:ListTagsOfResource",
          "dynamodb:TagResource",
          "dynamodb:UntagResource",
          "dynamodb:DescribeGlobalTable",
          "dynamodb:ListGlobalTables"
      ]
      Resource = "arn:aws:dynamodb:us-east-1:*:table/value"
    },

      # BACKEND: Secrets Manager 
    {
      Sid    = "SecretsManagerAccess"
      Effect = "Allow"
      Action = [
          "secretsmanager:CreateSecret",
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:TagResource",
          "secretsmanager:GetResourcePolicy"
      ]
      Resource = "arn:aws:secretsmanager:us-east-1:*:secret:travelease/*"
    },

      # BACKEND: CloudFront management

    {
      Sid    = "CloudFrontManagement"
      Effect = "Allow"
      Action = [
          "cloudfront:CreateDistribution",
          "cloudfront:GetDistribution",
          "cloudfront:UpdateDistribution",
          "cloudfront:DeleteDistribution",
          "cloudfront:GetDistributionConfig",
          "cloudfront:ListDistributions",
          "cloudfront:TagResource",
          "cloudfront:GetInvalidation",
          "cloudfront:CreateInvalidation",
          "cloudfront:ListTagsForResource"
      ]
      Resource = "arn:aws:cloudfront::675769453941:distribution/E1J02HSEWB11X6"
    },

      # BACKEND: IAM management

    {
      Sid    = "IAMManagement"
      Effect = "Allow"
      Action = [
          "iam:CreateRole",
          "iam:GetRole",
          "iam:UpdateRole",
          "iam:DeleteRole",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:PutRolePolicy",
          "iam:GetRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:CreatePolicy",
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:DeletePolicy",
          "iam:CreatePolicyVersion",
          "iam:ListPolicyVersions",
          "iam:DeletePolicyVersion",
          "iam:PassRole",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:CreateOpenIDConnectProvider",
          "iam:GetOpenIDConnectProvider",
          "iam:DeleteOpenIDConnectProvider",
          "iam:TagOpenIDConnectProvider",
          "iam:ListRoleTags",
          "iam:ListInstanceProfilesForRole"
      ]
      Resource = [
        "arn:aws:iam::*:role/travelease_lambda_role",
        "arn:aws:iam::*:role/github_role",
        "arn:aws:iam::*:policy/github-oidc-policy",
        "arn:aws:iam::*:policy/github*",
        "arn:aws:iam::*:policy/lambda-*",
        "arn:aws:iam::*:policy/lambda_*",
        "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
        "arn:aws:iam::*:oidc-provider/token.actions.githubusercontent.com"
      ]
    },

      # BACKEND: CloudWatch monitoring 

    {
      Sid    = "CloudWatchManagement"
      Effect = "Allow"
      Action = [
          "cloudwatch:PutMetricAlarm",
          "cloudwatch:DescribeAlarms",
          "cloudwatch:DeleteAlarms",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",
          "logs:CreateLogGroup",
          "logs:DescribeLogGroups",
          "logs:DeleteLogGroup",
          "logs:PutRetentionPolicy",
          "logs:DescribeLogStreams",
          "logs:ListTagsLogGroup",
          "logs:TagLogGroup",
          "logs:ListTagsForResource"
      ]
      Resource = [
        "arn:aws:cloudwatch:us-east-1:*:alarm:travelease-*",
        "arn:aws:logs:us-east-1:*:log-group:/aws/lambda/travelease-*"
      ]
    },

      # BACKEND: SNS notifications
    {
      Sid    = "SNSManagement"
      Effect = "Allow"
      Action = [
          "sns:CreateTopic",
          "sns:GetTopicAttributes",
          "sns:SetTopicAttributes",
          "sns:DeleteTopic",
          "sns:Subscribe",
          "sns:GetSubscriptionAttributes",
          "sns:Unsubscribe",
          "sns:ListSubscriptionsByTopic",
          "sns:ListTagsForResource",
          "sns:TagResource"
      ]
      Resource = "arn:aws:sns:us-east-1:*:travelease-*"
    },

    ]   # closes the statement
  })    # closes the policy = jsonencode({
}       # closes the IAM policy resource

# Attach the Policy to the IAM Role 
resource "aws_iam_role_policy_attachment" "github-attach" {
  role       = aws_iam_role.github_workflow.name
  policy_arn = aws_iam_policy.github_oidc_policy.arn
}

# SNS Topic Resource

resource "aws_sns_topic" "travelease_alerts" {
  name = "travelease-alerts"

  tags = {
    Project     = "TravelEase"
    Environment = "production"
  }
}

# SNS Email subscription

resource "aws_sns_topic_subscription" "email_alert" {
  topic_arn = aws_sns_topic.travelease_alerts.arn
  protocol  = "email"
  endpoint  = var.business_email
}

# CloudWatch Alarm 1 (Lambda error, duration and throttle)

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "travelease-lambda-errors"
  alarm_description   = "Lambda function is throwing errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.travelease_lambda.function_name
  }

  alarm_actions = [aws_sns_topic.travelease_alerts.arn]

  tags = {
    Project     = "TravelEase"
    Environment = "production"
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda_duration" {
  alarm_name          = "travelease-lambda-duration"
  alarm_description   = "Lambda duration exceeding 45 seconds - approaching 60s timeout"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Average"
  threshold           = 45000    # milliseconds - 45 seconds
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.travelease_lambda.function_name
  }

  alarm_actions = [aws_sns_topic.travelease_alerts.arn]

  tags = {
    Project     = "TravelEase"
    Environment = "production"
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  alarm_name          = "travelease-lambda-throttles"
  alarm_description   = "Lambda function is being throttled - submissions may be dropped"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.travelease_lambda.function_name
  }

  alarm_actions = [aws_sns_topic.travelease_alerts.arn]

  tags = {
    Project     = "TravelEase"
    Environment = "production"
  }
}

# CloudWatch Alarm 2 (DynamoDB Capacity Usage)
resource "aws_cloudwatch_metric_alarm" "dynamodb_throttles" {
  alarm_name          = "travelease-dynamodb-throttles"
  alarm_description   = "DynamoDB write requests are being throttled"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "WriteThrottleEvents"
  namespace           = "AWS/DynamoDB"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    TableName = aws_dynamodb_table.submissions.name
  }

  alarm_actions = [aws_sns_topic.travelease_alerts.arn]

  tags = {
    Project     = "TravelEase"
    Environment = "production"
  }
}

# DynamoDB Backup service



# Outputs for important resource values after deployment

output "api_endpoint" {
  description = "API Gateway invoke URL for form submission"
  value       = "${aws_api_gateway_stage.production.invoke_url}/submit"
}

output "s3_website_url" {
  description = "S3 static website endpoint"
  value       = "http://${aws_s3_bucket.my-bucket.bucket}.s3-website-${var.aws_region}.amazonaws.com"
}

output "dynamodb_table_name" {
  description = "DynamoDB table for submissions"
  value       = aws_dynamodb_table.submissions.name
}

output "lambda_function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.travelease_lambda.function_name
}

output "api_key_value" {
  description = "API key for frontend (keep secret!)"
  value       = aws_api_gateway_api_key.frontend_key.value
  sensitive   = true
}

output "cloudfront_url" {
  description = "Cloudfront distribution URL (HTTPS)"
  value       = "https://${aws_cloudfront_distribution.website_distribution.domain_name}"
}