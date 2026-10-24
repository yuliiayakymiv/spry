# How the application road reads what the infrastructure road created.
#
# Before: deploy-frontend.sh (also in GitHub Actions) read CloudFormation stack outputs.
# Now there are no stacks, and the CI job has no HCP Terraform token, so Terraform publishes the
# few values the scripts need as plain SSM parameters under /<project>/infra/, and the GitHub
# deploy role may read exactly that path. None of the values is secret: they all end up in the
# public JavaScript or in an AWS console anyway. On a laptop `terraform output` works as well.

locals {
  published = {
    cognito_authority = local.cognito_authority
    cognito_client_id = aws_cognito_user_pool_client.web.id
    cognito_domain    = local.cognito_domain
    parser_url        = aws_lambda_function_url.agenda_parser.function_url
    report_queue_url  = aws_sqs_queue.report_requests.url
  }
}

resource "aws_ssm_parameter" "published" {
  for_each    = local.published
  name        = "/${var.project_name}/infra/${each.key}"
  description = "Terraform output ${each.key} (infra/publish.tf)"
  type        = "String"
  value       = each.value
}

# Replaces the read-spry-auth / read-spry-ai inline policies that 07-auth.sh and 10-ai.sh
# put on the deploy role (cloudformation:DescribeStacks on two stacks that no longer exist).
resource "aws_iam_role_policy" "deploy_reads_infra" {
  name = "read-${var.project_name}-infra"
  role = var.deploy_role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
      Resource = [
        "arn:aws:ssm:${var.region}:${local.account_id}:parameter/${var.project_name}/infra",
        "arn:aws:ssm:${var.region}:${local.account_id}:parameter/${var.project_name}/infra/*",
      ]
    }]
  })
}
