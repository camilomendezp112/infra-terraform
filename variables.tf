variable "region" {
  default = "us-east-1"
}

variable "sentry_dsn" {
  description = "DSN de Sentry"
  type        = string
}
