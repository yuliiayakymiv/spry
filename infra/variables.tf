# ---------------------------------------------------------------- shared
variable "project_name" {
  type        = string
  default     = "spry"
  description = "Prefix of every resource name. Changing it renames (= re-creates) almost everything."
}

variable "region" {
  type    = string
  default = "eu-central-1"
}

# The Lab 2 stack (VPC, ECS, RDS, CloudFront) is still created by infra/aws/0*.sh.
# Terraform only reads it, through data sources in data.tf.
variable "ecs_cluster" {
  type    = string
  default = "spry"
}

variable "ecs_service" {
  type    = string
  default = "spry-backend"
}

variable "container_name" {
  type    = string
  default = "spry-backend"
}

variable "deploy_role_name" {
  type        = string
  default     = "spry-github-deploy"
  description = "GitHub Actions deploy role from 06-oidc.sh; gets read access to /<project>/infra/*"
}

# ---------------------------------------------------------------- auth.tf (Lab 4)
variable "cognito_domain_prefix" {
  type        = string
  description = "https://<prefix>.auth.<region>.amazoncognito.com"

  validation {
    condition     = can(regex("^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$", var.cognito_domain_prefix))
    error_message = "Lowercase letters, digits and hyphens only."
  }
}

variable "site_url" {
  type        = string
  description = "Public site origin without trailing slash, e.g. https://d1234abcd.cloudfront.net"

  validation {
    condition     = can(regex("^https://[^/]+$", var.site_url))
    error_message = "https://<host>, no path and no trailing slash."
  }
}

variable "local_url" {
  type    = string
  default = "http://localhost:5173"
}

variable "google_client_id" {
  type = string
}

variable "google_client_secret" {
  type        = string
  sensitive   = true
  description = "Set it in the HCP Terraform workspace as a sensitive Terraform variable. Never in a file."
}

# ---------------------------------------------------------------- reports.tf (Lab 5)
variable "report_recipients" {
  type        = string
  description = "Comma-separated. In the SES sandbox each one must be a verified identity."

  validation {
    condition     = can(regex("^[^,\\s]+@[^,\\s]+(,[^,\\s]+@[^,\\s]+)*$", var.report_recipients))
    error_message = "Comma-separated email addresses, no spaces."
  }
}

variable "report_sender_domain" {
  type        = string
  default     = ""
  description = "Optional: send from reports@<domain>. Empty: send from the first recipient."
}

variable "report_schedule" {
  type        = string
  default     = "cron(0 7 ? * MON *)"
  description = "Use rate(5 minutes) for one test run, then set it back."
}

variable "report_fail_week" {
  type        = string
  default     = ""
  description = "DLQ exercise only. The builder raises for this week (e.g. 2026-W39)."
}

# ---------------------------------------------------------------- ai.tf (Lab 6)
variable "parser_model" {
  type    = string
  default = "us.amazon.nova-pro-v1:0"

  validation {
    condition = contains([
      "us.amazon.nova-pro-v1:0", "us.amazon.nova-lite-v1:0", "us.amazon.nova-micro-v1:0",
      "anthropic.claude-opus-5-5", "anthropic.claude-sonnet-5-5", "anthropic.claude-haiku-5-5",
    ], var.parser_model)
    error_message = "Unknown model id (see ADR 0006)."
  }
}

variable "bedrock_region" {
  type    = string
  default = "us-east-1"
}

variable "budget_email" {
  type        = string
  description = "Where the monthly budget alert goes."
}

variable "budget_usd" {
  type    = number
  default = 5
}
