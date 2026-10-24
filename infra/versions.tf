terraform {
  required_version = ">= 1.10"

  # State lives in HCP Terraform, one workspace = one environment (dev).
  # Change the organization if yours is named differently.
  cloud {
    organization = "ooad-yuliiayakymiv"

    workspaces {
      name = "spry-dev"
    }
  }

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # 6.70+: aws_lambda_permission.invoked_via_function_url (ai.tf)
      version = "~> 6.70"
    }
    # Packs the report-mailer source (lambda/report_mailer/index.py) into a zip.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }
}

# Credentials: none here. In HCP Terraform the run assumes the bootstrap role through OIDC
# (workspace env vars TFC_AWS_PROVIDER_AUTH / TFC_AWS_RUN_ROLE_ARN).
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      PROJECT_NAME = var.project_name
      ManagedBy    = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
