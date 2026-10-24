# Weekly meetings report (Lab 5). Every Monday 07:00 Kyiv time EventBridge Scheduler puts a
# command on SQS; report-builder (backend image, in the VPC) reads RDS and writes
# reports/<week>.csv to S3 through a gateway endpoint; ObjectCreated starts report-mailer
# (outside the VPC), which emails the CSV through SES.
# Was infra/reports.yml (CloudFormation stack spry-reports).

locals {
  reports_bucket  = "${var.project_name}-reports-${local.account_id}"
  first_recipient = split(",", var.report_recipients)[0]
  report_sender   = var.report_sender_domain != "" ? "reports@${var.report_sender_domain}" : local.first_recipient
}

# ---------------------------------------------------------------- storage
# In the AWS provider the bucket's settings are separate resources that point at it. That is
# also why the Lab 5 circular dependency (bucket -> notification -> permission -> bucket ARN)
# is gone: the bucket no longer needs an explicit name trick or a DependsOn.
resource "aws_s3_bucket" "reports" {
  bucket = local.reports_bucket

  # Every weekly report lives here. Renaming the bucket would replace it: refuse instead.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket                  = aws_s3_bucket.reports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "reports" {
  bucket = aws_s3_bucket.reports.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    id     = "expire-reports"
    status = "Enabled"

    filter {
      prefix = "reports/"
    }

    expiration {
      days = 90
    }
  }
}

resource "aws_s3_bucket_notification" "reports" {
  bucket = aws_s3_bucket.reports.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.report_mailer.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "reports/"
    filter_suffix       = ".csv"
  }

  # S3 checks that it may invoke the function when the notification is saved.
  depends_on = [aws_lambda_permission.mailer_s3]
}

# The builder has no route to the internet (Lambda ENIs never get a public IP).
# Without this endpoint its PutObject hangs until the function times out. Gateway endpoints are free.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = data.aws_vpc.default.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [data.aws_route_table.main.id]
}

# ---------------------------------------------------------------- queue
resource "aws_sqs_queue" "report_requests_dlq" {
  name                      = "${var.project_name}-report-requests-dlq"
  message_retention_seconds = 1209600 # 14 days, the maximum
  max_message_size          = 1048576 # the AWS default since 2025 (1 MiB); the provider assumes 256 KiB
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "report_requests" {
  name = "${var.project_name}-report-requests"
  # 6 x the builder timeout: a message must not reappear while an attempt is still running.
  visibility_timeout_seconds = 360
  max_message_size           = 1048576 # the AWS default since 2025 (1 MiB)
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.report_requests_dlq.arn
    maxReceiveCount     = 3
  })
}

# ---------------------------------------------------------------- builder (in the VPC)
resource "aws_cloudwatch_log_group" "report_builder" {
  name              = "/aws/lambda/${var.project_name}-report-builder"
  retention_in_days = 14
}

resource "aws_iam_role" "report_builder" {
  name = "${var.project_name}-report-builder"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "report_builder_vpc" {
  role       = aws_iam_role.report_builder.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "report_builder" {
  name = "build-reports"
  role = aws_iam_role.report_builder.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.reports.arn}/reports/*"
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.report_requests.arn
      },
    ]
  })
}

resource "aws_lambda_function" "report_builder" {
  function_name = "${var.project_name}-report-builder"
  description   = "Builds reports/<ISO week>.csv from the meetings database"
  role          = aws_iam_role.report_builder.arn
  package_type  = "Image"
  image_uri     = local.backend_image
  architectures = ["x86_64"]
  memory_size   = 512
  timeout       = 60

  # The API image runs uvicorn; here the same image runs the Lambda runtime client instead.
  image_config {
    entry_point       = ["python", "-m", "awslambdaric"]
    command           = ["app.reports.lambda_handler.handler"]
    working_directory = "/app"
  }

  vpc_config {
    subnet_ids         = data.aws_subnets.default.ids
    security_group_ids = [data.aws_security_group.ecs.id]
  }

  environment {
    variables = {
      DATABASE_URL     = data.aws_ssm_parameter.database_url.value
      REPORTS_BUCKET   = aws_s3_bucket.reports.bucket
      REPORT_TZ        = "Europe/Kyiv"
      REPORT_FAIL_WEEK = var.report_fail_week
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.report_builder.name
  }

  # The image is the application's, not the infrastructure's: `make lambda-images` moves it
  # to the image the API runs. Terraform owns everything else about the function.
  lifecycle {
    ignore_changes = [image_uri]
  }
}

# The Lambda service polls the queue and invokes the builder; the builder never talks to SQS,
# which is why this works from a VPC without NAT.
resource "aws_lambda_event_source_mapping" "report_builder" {
  event_source_arn = aws_sqs_queue.report_requests.arn
  function_name    = aws_lambda_function.report_builder.arn
  batch_size       = 1

  scaling_config {
    maximum_concurrency = 2 # the rest waits in the queue instead of crowding RDS
  }
}

# ---------------------------------------------------------------- schedule
resource "aws_iam_role" "report_scheduler" {
  name = "${var.project_name}-report-scheduler"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "report_scheduler" {
  name = "send-report-requests"
  role = aws_iam_role.report_scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sqs:SendMessage"
      Resource = aws_sqs_queue.report_requests.arn
    }]
  })
}

resource "aws_scheduler_schedule" "weekly_report" {
  name                = "${var.project_name}-weekly-report"
  description         = "Monday 07:00 Kyiv time, report for the previous ISO week"
  schedule_expression = var.report_schedule
  # Without it the cron runs in UTC: 09:00 or 10:00 in Kyiv depending on DST.
  schedule_expression_timezone = "Europe/Kyiv"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_sqs_queue.report_requests.arn
    role_arn = aws_iam_role.report_scheduler.arn
    input    = "{\"week\": null, \"source\": \"schedule\"}"
  }
}

# ---------------------------------------------------------------- mailer (outside the VPC)
resource "aws_cloudwatch_log_group" "report_mailer" {
  name              = "/aws/lambda/${var.project_name}-report-mailer"
  retention_in_days = 14
}

resource "aws_iam_role" "report_mailer" {
  name = "${var.project_name}-report-mailer"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "report_mailer_logs" {
  role       = aws_iam_role.report_mailer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "report_mailer" {
  name = "mail-reports"
  role = aws_iam_role.report_mailer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Read only. A function triggered by uploads to reports/ must never write there:
      # it would trigger itself forever.
      {
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.reports.arn}/reports/*"
      },
      # In the sandbox SES checks the recipient identities too, hence identity/*.
      {
        Effect   = "Allow"
        Action   = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = "arn:aws:ses:${var.region}:${local.account_id}:identity/*"
      },
    ]
  })
}

data "archive_file" "report_mailer" {
  type        = "zip"
  source_file = "${path.module}/lambda/report_mailer/index.py"
  output_path = "${path.module}/.build/report_mailer.zip"
}

resource "aws_lambda_function" "report_mailer" {
  function_name    = "${var.project_name}-report-mailer"
  description      = "Emails a new reports/*.csv through SES"
  role             = aws_iam_role.report_mailer.arn
  runtime          = "python3.13"
  handler          = "index.handler"
  architectures    = ["arm64"]
  memory_size      = 256
  timeout          = 30
  filename         = data.archive_file.report_mailer.output_path
  source_code_hash = data.archive_file.report_mailer.output_base64sha256

  environment {
    variables = {
      SENDER     = local.report_sender
      RECIPIENTS = var.report_recipients
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.report_mailer.name
  }
}

# Re-created, not imported (a child resource; CloudFormation had given it a random statement id).
resource "aws_lambda_permission" "mailer_s3" {
  statement_id   = "AllowS3InvokeFromReportsBucket"
  function_name  = aws_lambda_function.report_mailer.function_name
  action         = "lambda:InvokeFunction"
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.reports.arn
  source_account = local.account_id
}

# ---------------------------------------------------------------- SES
# Sandbox: the recipient must be verified too. AWS emails a confirmation link to this address.
resource "aws_sesv2_email_identity" "recipient" {
  email_identity = local.first_recipient
}

resource "aws_sesv2_email_identity" "domain" {
  count          = var.report_sender_domain != "" ? 1 : 0
  email_identity = var.report_sender_domain
}
