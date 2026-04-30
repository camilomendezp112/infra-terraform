provider "aws" {
  region = "us-east-1"
}

resource "aws_s3_bucket" "infrastructure_project123456" {
  bucket = "mi-bucket-prueba-123456"
}
