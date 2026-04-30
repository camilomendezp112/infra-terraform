provider "aws" {
  region = "us-east-1"
}

resource "aws_s3_bucket" "mi_bucket_infrastructure" {
  bucket = "mi-bucket-prueba-123456"
}
