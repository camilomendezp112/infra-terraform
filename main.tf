provider "aws" {
  region = "us-east-1"
}

resource "random_id" "bucket_id" {
  byte_length = 4
}

resource "aws_s3_bucket" "asset_management" {
  bucket = "camilo-${random_id.bucket_id.hex}"
}

resource "aws_lambda_function" "mi_lambda" {
  function_name = "mi-lambda"

  role = aws_iam_role.lambda_role.arn

  handler = "index.handler"
  runtime = "nodejs18.x"

  filename = "dummy.zip"
}

