################################################################################
# AWS SaaS Multi-Tenant Inventory Management System (SaaS Architecture)
# Architect: Antigravity AI
# Focus: Scalability, Security, and Clean Infrastructure (Terraform)
################################################################################

# --- VARIABLES ---
variable "aws_region" {
  description = "AWS Region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name of the project for tagging and naming"
  type        = string
  default     = "asset-management-saas"
}

provider "aws" {
  region = var.aws_region
}



# --- 2. AMAZON COGNITO (AUTHENTICATION) ---
resource "aws_cognito_user_pool" "pool" {
  name = "${var.project_name}-user-pool"

  alias_attributes         = ["email"]
  auto_verified_attributes = ["email"]

  schema {
    attribute_data_type = "String"
    name                = "tenant_id"
    mutable             = true
    string_attribute_constraints {
      min_length = 1
      max_length = 50
    }
  }

  schema {
    attribute_data_type = "String"
    name                = "role"
    mutable             = true
    string_attribute_constraints {
      min_length = 1
      max_length = 20
    }
  }

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_symbols   = true
    require_uppercase = true
  }

  lambda_config {
    post_confirmation = aws_lambda_function.functions["syncUser"].arn
  }

  tags = {
    Project = var.project_name
  }
}

resource "aws_cognito_user_pool_client" "client" {
  name         = "${var.project_name}-app-client"
  user_pool_id = aws_cognito_user_pool.pool.id

  # No client secret for frontend integration (React/S3)
  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_SRP_AUTH"
  ]
}

# --- 3. DYNAMODB (MULTI-TENANT DESIGN) ---
resource "aws_dynamodb_table" "assets" {
  name         = "Assets"
  billing_mode = "PAY_PER_REQUEST" # Serverless scaling
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }

  attribute {
    name = "SK"
    type = "S"
  }

  attribute {
    name = "status"
    type = "S"
  }

  attribute {
    name = "created_at"
    type = "S"
  }

  attribute {
    name = "user_id"
    type = "S"
  }

  attribute {
    name = "type"
    type = "S"
  }

  # GSI1: Analítica y Reportes
  global_secondary_index {
    name            = "GSI1"
    hash_key        = "status"
    range_key       = "created_at"
    projection_type = "ALL"
  }

  # GSI_User: Buscar activos por usuario dentro de un tenant
  global_secondary_index {
    name            = "GSI_User"
    hash_key        = "PK"
    range_key       = "user_id"
    projection_type = "ALL"
  }

  # GSI_Type: Buscar activos por tipo dentro de un tenant
  global_secondary_index {
    name            = "GSI_Type"
    hash_key        = "PK"
    range_key       = "type"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Project = var.project_name
  }
}

# --- 4. IAM ROLES (SECURITY PRO) ---
resource "aws_iam_role" "lambda_exec" {
  name = "${var.project_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Sid    = ""
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.project_name}-lambda-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Effect = "Allow"
        Resource = [
          aws_dynamodb_table.assets.arn,
          "${aws_dynamodb_table.assets.arn}/index/GSI1",
          "${aws_dynamodb_table.assets.arn}/index/GSI_User",
          "${aws_dynamodb_table.assets.arn}/index/GSI_Type"
        ]
      },
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Effect   = "Allow"
        Resource = [
          for lambda_name in ["manageAsset", "getAssets", "syncUser"] : 
          "${aws_cloudwatch_log_group.logs[lambda_name].arn}:*"
        ]
      }
    ]
  })
}

# --- 5. CLOUDWATCH LOGS ---
resource "aws_cloudwatch_log_group" "logs" {
  for_each          = toset(["manageAsset", "getAssets", "syncUser"])
  name              = "/aws/lambda/${var.project_name}-${each.key}"
  retention_in_days = 14
}

# --- 6. LAMBDA FUNCTIONS ---
resource "aws_lambda_function" "functions" {
  for_each      = toset(["manageAsset", "getAssets", "syncUser"])
  function_name = "${var.project_name}-${each.key}"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "app.lambda_handler"
  runtime       = "python3.11"
  timeout       = 10

filename = "dummy.zip"

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.assets.name
    }
  }

lifecycle {
  ignore_changes = [
    filename,
    source_code_hash
  ]
}

  depends_on = [aws_cloudwatch_log_group.logs]
}

# Allow Cognito to invoke syncUser lambda
resource "aws_lambda_permission" "cognito" {
  statement_id  = "AllowExecutionFromCognito"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.functions["syncUser"].function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.pool.arn
}

# --- 7. API GATEWAY (REST API V1) ---
resource "aws_api_gateway_rest_api" "api" {
  name        = "${var.project_name}-api"
  description = "Hardened REST API for Asset Management"
}

# Authorizer
resource "aws_api_gateway_authorizer" "cognito" {
  name          = "cognito-authorizer"
  type          = "COGNITO_USER_POOLS"
  rest_api_id   = aws_api_gateway_rest_api.api.id
  provider_arns = [aws_cognito_user_pool.pool.arn]
}

# Resource /assets
resource "aws_api_gateway_resource" "assets" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "assets"
}

# Validation Model for POST/PUT /assets
resource "aws_api_gateway_model" "asset_model" {
  rest_api_id  = aws_api_gateway_rest_api.api.id
  name         = "AssetModel"
  description  = "Validates required fields and blocks malicious extra fields"
  content_type = "application/json"

  schema = jsonencode({
    type                 = "object"
    additionalProperties = false
    required             = ["name", "type"]
    properties = {
      id      = { type = "string" }
      name    = { type = "string", minLength = 1 }
      type    = { type = "string", minLength = 1 }
      modelo  = { type = "string" }
      status  = { type = "string" }
      user_id = { type = "string" }
    }
  })
}

resource "aws_api_gateway_request_validator" "validator" {
  name                        = "StrictBodyValidator"
  rest_api_id                 = aws_api_gateway_rest_api.api.id
  validate_request_body       = true
  validate_request_parameters = false
}

# --- Methods ---

# GET /assets
resource "aws_api_gateway_method" "get_assets" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.assets.id
  http_method   = "GET"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}

resource "aws_api_gateway_integration" "get_assets_integration" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.assets.id
  http_method             = aws_api_gateway_method.get_assets.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.functions["getAssets"].invoke_arn
}

# POST /assets
resource "aws_api_gateway_method" "post_assets" {
  rest_api_id          = aws_api_gateway_rest_api.api.id
  resource_id          = aws_api_gateway_resource.assets.id
  http_method          = "POST"
  authorization        = "COGNITO_USER_POOLS"
  authorizer_id        = aws_api_gateway_authorizer.cognito.id
  request_models       = { "application/json" = aws_api_gateway_model.asset_model.name }
  request_validator_id = aws_api_gateway_request_validator.validator.id
}

resource "aws_api_gateway_integration" "post_assets_integration" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.assets.id
  http_method             = aws_api_gateway_method.post_assets.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.functions["manageAsset"].invoke_arn
}

# PUT /assets
resource "aws_api_gateway_method" "put_assets" {
  rest_api_id          = aws_api_gateway_rest_api.api.id
  resource_id          = aws_api_gateway_resource.assets.id
  http_method          = "PUT"
  authorization        = "COGNITO_USER_POOLS"
  authorizer_id        = aws_api_gateway_authorizer.cognito.id
  request_models       = { "application/json" = aws_api_gateway_model.asset_model.name }
  request_validator_id = aws_api_gateway_request_validator.validator.id
}

resource "aws_api_gateway_integration" "put_assets_integration" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.assets.id
  http_method             = aws_api_gateway_method.put_assets.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.functions["manageAsset"].invoke_arn
}

# DELETE /assets
resource "aws_api_gateway_method" "delete_assets" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.assets.id
  http_method   = "DELETE"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}

resource "aws_api_gateway_integration" "delete_assets_integration" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.assets.id
  http_method             = aws_api_gateway_method.delete_assets.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.functions["manageAsset"].invoke_arn
}

# Deployment
resource "aws_api_gateway_deployment" "deployment" {
  depends_on = [
    aws_api_gateway_integration.get_assets_integration,
    aws_api_gateway_integration.post_assets_integration,
    aws_api_gateway_integration.put_assets_integration,
    aws_api_gateway_integration.delete_assets_integration
  ]
  rest_api_id = aws_api_gateway_rest_api.api.id

  lifecycle {
    create_before_destroy = true
  }
}

# Stage with Throttling
resource "aws_api_gateway_stage" "prod" {
  deployment_id = aws_api_gateway_deployment.deployment.id
  rest_api_id   = aws_api_gateway_rest_api.api.id
  stage_name    = "prod"
}

resource "aws_api_gateway_method_settings" "throttling" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  stage_name  = aws_api_gateway_stage.prod.stage_name
  method_path = "*/*"

  settings {
    throttling_burst_limit = 10
    throttling_rate_limit  = 5
  }
}

# Lambda Permissions for API Gateway
resource "aws_lambda_permission" "api_gw_manage" {
  statement_id  = "AllowExecutionFromAPIGatewayManage"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.functions["manageAsset"].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "api_gw_get" {
  statement_id  = "AllowExecutionFromAPIGatewayGet"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.functions["getAssets"].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}

# --- 8. OUTPUTS ---
output "api_url" {
  description = "URL del API Gateway para el frontend"
  value       = "${aws_api_gateway_stage.prod.invoke_url}/assets"
}

output "cognito_user_pool_id" {
  description = "ID del User Pool de Cognito"
  value       = aws_cognito_user_pool.pool.id
}

output "cognito_app_client_id" {
  description = "ID del App Client de Cognito"
  value       = aws_cognito_user_pool_client.client.id
}

output "dynamodb_table_name" {
  description = "Nombre de la tabla DynamoDB"
  value       = aws_dynamodb_table.assets.name
}

################################################################################
# NOTA FINAL SOBRE MULTI-TENANCY Y SEGURIDAD:
# 1. El aislamiento de datos se garantiza en el código de la Lambda.
# 2. La Lambda lee el 'tenant_id' del token JWT validado por API Gateway.
# 3. Nunca confíes en un 'tenant_id' enviado en el cuerpo del JSON (body) por el cliente.
# 4. Al usar PK=TENANT#<id>, garantizas que las consultas (Query) sean eficientes por empresa.
################################################################################
