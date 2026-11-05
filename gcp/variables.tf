variable "project_id" {
  type        = string
  description = "Google Cloud project ID (permanent, globally unique)"
}

variable "project_name" {
  type    = string
  default = "spry"
}

variable "region" {
  type = string
  # EU, as Spry on AWS (eu-central-1, NFR-7: personal data stays in the EU). Belgium is a Tier 1
  # region: Cloud Run and Cloud SQL cost the same as in us-central1.
  default = "europe-west1"
}

variable "db_tier" {
  type    = string
  default = "db-f1-micro"
}

variable "db_activation_policy" {
  type = string
  # ALWAYS = running and billing per hour; NEVER = stopped (only storage bills). See gcp/README.md.
  default = "ALWAYS"

  validation {
    condition     = contains(["ALWAYS", "NEVER"], var.db_activation_policy)
    error_message = "ALWAYS or NEVER."
  }
}

# Sign-in stays on AWS (Cognito, infra/auth.tf). The API on Cloud Run verifies Cognito tokens itself,
# which is why the service may allow unauthenticated invocations.
variable "cognito_issuer" {
  type        = string
  description = "https://cognito-idp.eu-central-1.amazonaws.com/<user pool id>"
}

variable "cognito_client_id" {
  type = string
}
