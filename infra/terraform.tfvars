# Non-secret values only. The Google client secret is a sensitive variable in the
# HCP Terraform workspace. Generated from the live resources by infra/migrate/1-retain-and-collect.sh.
project_name = "spry"
region       = "eu-central-1"

# auth.tf
cognito_domain_prefix = "spry-yuliia"
site_url              = "https://d1rjthazsn1a8j.cloudfront.net"
google_client_id      = "556813383999-lulkcr8h3bctmiogtcjs7e7u79br696g.apps.googleusercontent.com"

# reports.tf
report_recipients    = "yuliaa.yakymiv@gmail.com"
report_sender_domain = ""
report_schedule      = "cron(0 7 ? * MON *)"
report_fail_week     = ""

# ai.tf
parser_model   = "us.amazon.nova-pro-v1:0"
bedrock_region = "us-east-1"
budget_email   = "yuliaa.yakymiv@gmail.com"
budget_usd     = 5
