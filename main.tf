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

# --- 1. AMAZON COGNITO (AUTHENTICATION) ---
# Multi-tenant authentication strategy: 
# Each user belongs to a tenant (tenant_id) and has a role (admin/user).
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

# --- 2. DYNAMODB (MULTI-TENANT DESIGN) ---
# DESIGN CLAVE: Single-Table Design
# PK = TENANT#<tenant_id> -> Grouping data by tenant ensures isolation and data locality.
# SK = ASSET#<asset_id>   -> Unique identifier for each asset within the tenant.
#
# 🔥 PREVENCIÓN DE HOT PARTITIONS (SCALABILITY):
# Para tenants masivos con millones de activos, se recomienda Sharding de la PK:
# PK = TENANT#<tenant_id>#<shard_id> (donde shard_id es un hash o numero aleatorio 1-N).
# Esto distribuye el tráfico a través de múltiples particiones físicas de DynamoDB.

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

  # GSI1: Analítica y Reportes
  # Permite buscar activos por estado ordenados por fecha de creación.
  global_secondary_index {
    name            = "GSI1"
    hash_key        = "status"
    range_key       = "created_at"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Project = var.project_name
  }
}

# --- 3. IAM ROLES (SECURITY PRO) ---
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
        Effect   = "Allow"
        Resource = [
          aws_dynamodb_table.assets.arn,
          "${aws_dynamodb_table.assets.arn}/index/*"
        ]
      },
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Effect   = "Allow"
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# --- 4. CLOUDWATCH LOGS ---
resource "aws_cloudwatch_log_group" "logs" {
  for_each          = toset(["createAsset", "getAssets", "updateAsset", "deleteAsset"])
  name              = "/aws/lambda/${var.project_name}-${each.key}"
  retention_in_days = 14
}

# --- 5. LAMBDA FUNCTIONS ---
# ⚠️ Multi-tenancy Enforcement:
# Las lambdas deben extraer 'tenant_id' del JWT Token (custom:tenant_id) 
# y usarlo para construir la PK (TENANT#tenant_id).

resource "aws_lambda_function" "functions" {
  for_each      = toset(["createAsset", "getAssets", "updateAsset", "deleteAsset"])
  function_name = "${var.project_name}-${each.key}"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "app.lambda_handler"
  runtime       = "python3.11"
  timeout       = 10

  filename         = "lambda/${each.key}.zip"
  source_code_hash = filebase64sha256("lambda/${each.key}.zip")

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.assets.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.logs]
}

# --- 6. API GATEWAY (HTTP API V2) ---
resource "aws_apigatewayv2_api" "api" {
  name          = "${var.project_name}-api"
  protocol_type = "HTTP"
  
  cors_configuration {
    allow_origins = ["*"] # Ajustar para producción (e.g., URL de S3)
    allow_methods = ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
    allow_headers = ["content-type", "authorization"]
  }
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true
}

# JWT Authorizer con Cognito
resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.api.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "cognito-authorizer"

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.client.id]
    issuer   = "https://${aws_cognito_user_pool.pool.endpoint}"
  }
}

# Integrations
resource "aws_apigatewayv2_integration" "integrations" {
  for_each           = aws_lambda_function.functions
  api_id             = aws_apigatewayv2_api.api.id
  integration_type   = "AWS_PROXY"
  integration_uri    = each.value.invoke_arn
  integration_method = "POST"
  payload_format_version = "2.0"
}

# Routes
resource "aws_apigatewayv2_route" "routes" {
  api_id    = aws_apigatewayv2_api.api.id
  authorizer_id = aws_apigatewayv2_authorizer.cognito.id
  authorization_type = "JWT"

  for_each = {
    "POST /assets"   = "createAsset"
    "GET /assets"    = "getAssets"
    "PUT /assets"    = "updateAsset"
    "DELETE /assets" = "deleteAsset"
  }

  route_key = each.key
  target    = "integrations/${aws_apigatewayv2_integration.integrations[each.value].id}"
}

# Lambda Permissions for API Gateway
resource "aws_lambda_permission" "api_gw" {
  for_each      = aws_lambda_function.functions
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = each.value.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

# --- 7. OUTPUTS ---
output "api_url" {
  description = "URL del API Gateway para el frontend"
  value       = aws_apigatewayv2_stage.default.invoke_url
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
