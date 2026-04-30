provider "aws" {
  region = "us-east-1"
}

resource "random_id" "bucket_id" {
  byte_length = 4
}

resource "aws_s3_bucket" "asset_management" {
  bucket = "camilo-${random_id.bucket_id.hex}"
}

