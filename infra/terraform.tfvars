# Non-secret values only. The Google client secret is a sensitive variable in the HCP Terraform
# workspace. infra/migrate/1-retain-and-collect.sh overwrites this file with the real values
# read from AWS; check them and commit.
project_name = "spry"
region       = "eu-central-1"

# auth.tf
cognito_domain_prefix = "spry-CHANGE-ME"
site_url              = "https://CHANGE-ME.cloudfront.net"
google_client_id      = "CHANGE-ME.apps.googleusercontent.com"

# reports.tf
report_recipients    = "change-me@example.com"
report_sender_domain = ""
report_schedule      = "cron(0 7 ? * MON *)"
report_fail_week     = ""

# ai.tf
parser_model   = "us.amazon.nova-pro-v1:0"
bedrock_region = "us-east-1"
budget_email   = "change-me@example.com"
budget_usd     = 5
