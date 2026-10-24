# "Paste an agenda" (Lab 6). The agenda-parser Lambda (backend image, OUTSIDE the VPC) has a
# public function URL; it checks the Cognito access token, calls the model on Amazon Bedrock and
# returns a validated agenda as JSON. It never writes anything: Save goes through the API.
# Was infra/ai.yml (CloudFormation stack spry-ai). Model region: var.bedrock_region.

resource "aws_cloudwatch_log_group" "agenda_parser" {
  name              = "/aws/lambda/${var.project_name}-agenda-parser"
  retention_in_days = 14
}

resource "aws_iam_role" "agenda_parser" {
  name = "${var.project_name}-agenda-parser"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Logs only. No VPC access, no database, no S3: the parser holds no data at all.
resource "aws_iam_role_policy_attachment" "agenda_parser_logs" {
  role       = aws_iam_role.agenda_parser.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "agenda_parser" {
  name = "call-claude"
  role = aws_iam_role.agenda_parser.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # "*" for now, as Lab 6 says. Narrowing it is a discussion question (docs/LAB6.md).
      # Claude through the Anthropic Messages API (bedrock-mantle):
      {
        Effect   = "Allow"
        Action   = "bedrock-mantle:CreateInference"
        Resource = "*"
      },
      # Nova through the Converse API (bedrock-runtime). A us.* inference profile
      # routes to several US regions, so both the profile and the models need it.
      {
        Effect   = "Allow"
        Action   = "bedrock:InvokeModel"
        Resource = "*"
      },
    ]
  })
}

resource "aws_lambda_function" "agenda_parser" {
  function_name = "${var.project_name}-agenda-parser"
  description   = "Paste an agenda - free text to a suggested agenda (model on Bedrock)"
  role          = aws_iam_role.agenda_parser.arn
  package_type  = "Image"
  image_uri     = local.backend_image
  architectures = ["x86_64"]
  memory_size   = 512
  timeout       = 30

  # Same image as the API, the Lambda runtime client and another handler (as in Lab 5).
  image_config {
    entry_point       = ["python", "-m", "awslambdaric"]
    command           = ["app.ai.agenda_lambda.handler"]
    working_directory = "/app"
  }

  # No vpc_config: outside the VPC it reaches Bedrock and Cognito's JWKS over the internet,
  # with no NAT gateway and no interface endpoint.
  environment {
    variables = {
      PARSER_MODEL      = var.parser_model
      BEDROCK_REGION    = var.bedrock_region
      COGNITO_ISSUER    = local.cognito_authority
      COGNITO_CLIENT_ID = aws_cognito_user_pool_client.web.id
      PARSER_MAX_CHARS  = "10000"
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.agenda_parser.name
  }

  # Image updates come from `make lambda-images` (see reports.tf).
  lifecycle {
    ignore_changes = [image_uri]
  }
}

resource "aws_lambda_function_url" "agenda_parser" {
  function_name = aws_lambda_function.agenda_parser.function_name
  # Public URL; the handler itself checks the Cognito token and returns 401 without one.
  authorization_type = "NONE"

  cors {
    allow_origins = [var.site_url, var.local_url]
    allow_methods = ["POST"]
    allow_headers = ["authorization", "content-type"]
    max_age       = 3600
  }
}

# A public function URL needs both permissions (AWS has required the second one since 2025).
# Both re-created, not imported: CloudFormation had given them random statement ids.
resource "aws_lambda_permission" "parser_url" {
  statement_id           = "AllowPublicFunctionUrl"
  function_name          = aws_lambda_function.agenda_parser.function_name
  action                 = "lambda:InvokeFunctionUrl"
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "parser_invoke" {
  statement_id             = "AllowInvokeViaFunctionUrl"
  function_name            = aws_lambda_function.agenda_parser.function_name
  action                   = "lambda:InvokeFunction"
  principal                = "*"
  invoked_via_function_url = true
}

# The cheapest insurance in the course: an email when the month's bill passes the limit.
resource "aws_budgets_budget" "monthly" {
  name         = "${var.project_name}-monthly"
  budget_type  = "COST"
  time_unit    = "MONTHLY"
  limit_amount = tostring(var.budget_usd)
  limit_unit   = "USD"

  notification {
    notification_type          = "ACTUAL"
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    notification_type          = "FORECASTED"
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [var.budget_email]
  }
}
