locals {
  cognito_authority = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
  cognito_domain    = "https://${var.cognito_domain_prefix}.auth.${var.region}.amazoncognito.com"
}

# ---------------------------------------------------------------- auth
output "user_pool_id" {
  value = aws_cognito_user_pool.main.id
}

output "user_pool_client_id" {
  value = aws_cognito_user_pool_client.web.id
}

output "cognito_authority" {
  description = "OIDC issuer; VITE_COGNITO_AUTHORITY"
  value       = local.cognito_authority
}

output "cognito_domain" {
  description = "Managed login base URL; VITE_COGNITO_DOMAIN"
  value       = local.cognito_domain
}

output "google_redirect_uri" {
  description = "Paste into the Google OAuth client as Authorised redirect URI"
  value       = "${local.cognito_domain}/oauth2/idpresponse"
}

# ---------------------------------------------------------------- reports
output "reports_bucket" {
  value = aws_s3_bucket.reports.bucket
}

output "report_queue_url" {
  value = aws_sqs_queue.report_requests.url
}

output "report_dlq_url" {
  value = aws_sqs_queue.report_requests_dlq.url
}

output "report_builder_log_group" {
  value = aws_cloudwatch_log_group.report_builder.name
}

output "report_mailer_log_group" {
  value = aws_cloudwatch_log_group.report_mailer.name
}

output "dkim_records" {
  description = "CNAMEs for your DNS provider (only with report_sender_domain)"
  value = [
    for token in try(aws_sesv2_email_identity.domain[0].dkim_signing_attributes[0].tokens, []) :
    "${token}._domainkey.${var.report_sender_domain} CNAME ${token}.dkim.amazonses.com"
  ]
}

# ---------------------------------------------------------------- ai
output "parser_url" {
  description = "VITE_PARSER_URL for the frontend build"
  value       = aws_lambda_function_url.agenda_parser.function_url
}

output "parser_log_group" {
  value = aws_cloudwatch_log_group.agenda_parser.name
}
