provider "aws" {
  region = "us-east-1"
}

resource "aws_s3_bucket" "asset_management_infrastructure_project123456" {
  bucket = "asset_management_infrastructure_project123456"
}
