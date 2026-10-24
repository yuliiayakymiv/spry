# One-time bootstrap (Lab 7, Part 1 Step 7): lets HCP Terraform reach AWS without stored keys.
# Run ONCE from a laptop with your own AWS credentials (aws configure). Local state on purpose:
# this is the piece that must exist before HCP Terraform can do anything. terraform.tfstate here
# is git-ignored; keep it (or re-import the two resources if it is lost).
#
#   cd infra/bootstrap
#   terraform init
#   terraform apply
#   terraform output role_arn   -> HCP Terraform workspace variable TFC_AWS_RUN_ROLE_ARN

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

variable "tfc_organization" {
  type    = string
  default = "ooad-yuliiayakymiv"
}

provider "aws" {
  region = "eu-central-1"

  default_tags {
    tags = {
      PROJECT_NAME = "spry"
      ManagedBy    = "terraform-bootstrap"
    }
  }
}

data "tls_certificate" "tfc" {
  url = "https://app.terraform.io"
}

resource "aws_iam_openid_connect_provider" "tfc" {
  url             = "https://app.terraform.io"
  client_id_list  = ["aws.workload.identity"]
  thumbprint_list = [data.tls_certificate.tfc.certificates[0].sha1_fingerprint]
}

resource "aws_iam_role" "tfc" {
  name = "hcp-terraform-${var.tfc_organization}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.tfc.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "app.terraform.io:aud" = "aws.workload.identity" }
        StringLike = {
          "app.terraform.io:sub" = "organization:${var.tfc_organization}:project:*:workspace:*:run_phase:*"
        }
      }
    }]
  })
}

# For the class project. A real team narrows this to the services the workspace manages
# (docs/LAB7.md, Step 7 question 5).
resource "aws_iam_role_policy_attachment" "tfc" {
  role       = aws_iam_role.tfc.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "role_arn" {
  value = aws_iam_role.tfc.arn
}
