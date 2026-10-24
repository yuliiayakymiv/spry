# Sign-in (Lab 4): Cognito user pool with email + password and Google, managed login v2.
# Was infra/auth.yml (CloudFormation stack spry-auth). Every name is unchanged, so the
# resources were imported, not re-created.

resource "aws_cognito_user_pool" "main" {
  name                     = "${var.project_name}-users"
  user_pool_tier           = "ESSENTIALS" # managed login needs Essentials; first 10,000 MAU free
  username_attributes      = ["email"]    # sign in with an email, no separate username
  auto_verified_attributes = ["email"]    # Cognito emails a confirmation code
  deletion_protection      = "INACTIVE"   # so teardown works after grading

  username_configuration {
    case_sensitive = false
  }

  admin_create_user_config {
    allow_admin_create_user_only = false # self sign-up stays ON (the lecturer signs up)
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  password_policy {
    minimum_length                   = 10
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  # Cognito's standard email attribute, written out exactly as Cognito reports it.
  schema {
    name                     = "email"
    attribute_data_type      = "String"
    required                 = true
    mutable                  = true
    developer_only_attribute = false

    string_attribute_constraints {
      min_length = "0"
      max_length = "2048"
    }
  }

  # Every account that signed up since Lab 4 lives here. A plan that wants to replace the pool
  # (e.g. a change to username_attributes) now fails instead of deleting them.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_cognito_identity_provider" "google" {
  user_pool_id  = aws_cognito_user_pool.main.id
  provider_name = "Google"
  provider_type = "Google"

  provider_details = {
    client_id        = var.google_client_id
    client_secret    = var.google_client_secret
    authorize_scopes = "openid email profile"
    # Cognito fills these in for Google itself; listed so the plan does not try to remove them.
    attributes_url                = "https://people.googleapis.com/v1/people/me?personFields="
    attributes_url_add_attributes = "true"
    authorize_url                 = "https://accounts.google.com/o/oauth2/v2/auth"
    oidc_issuer                   = "https://accounts.google.com"
    token_request_method          = "POST"
    token_url                     = "https://www.googleapis.com/oauth2/v4/token"
  }

  attribute_mapping = { # without this a Google user arrives with no email to show
    email          = "email"
    email_verified = "email_verified"
    name           = "name"
    username       = "sub" # added by Cognito
  }
}

resource "aws_cognito_user_pool_client" "web" {
  name         = "${var.project_name}-web"
  user_pool_id = aws_cognito_user_pool.main.id

  # Public client, no secret (a browser cannot keep one -> PKCE). `generate_secret` is left out on
  # purpose: AWS never reports it back, so after an import `false` here would force a replacement
  # of the client, i.e. a new client id.
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  # A reference, not the string "Google": Terraform creates the provider first. No depends_on.
  supported_identity_providers = ["COGNITO", aws_cognito_identity_provider.google.provider_name]

  # Must match redirect_uri byte for byte, trailing slash included.
  callback_urls = ["${var.site_url}/", "${var.local_url}/"]
  logout_urls   = ["${var.site_url}/", "${var.local_url}/"]

  explicit_auth_flows           = ["ALLOW_REFRESH_TOKEN_AUTH"]
  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }
}

resource "aws_cognito_user_pool_domain" "main" {
  domain                = var.cognito_domain_prefix
  user_pool_id          = aws_cognito_user_pool.main.id
  managed_login_version = 2
}

# The look of the sign-in page. Terraform reads the files in branding/ directly, so the
# render.py step that pasted Base64 into auth.yml is gone. Edit the files, open a PR.
resource "aws_cognito_managed_login_branding" "main" {
  user_pool_id = aws_cognito_user_pool.main.id
  client_id    = aws_cognito_user_pool_client.web.id
  settings     = jsonencode(jsondecode(file("${path.module}/branding/settings.json")))

  dynamic "asset" {
    for_each = {
      "medallion.svg"       = "FAVICON_SVG"
      "footer-text.svg"     = "PAGE_FOOTER_LOGO"
      "page-background.svg" = "PAGE_BACKGROUND"
    }
    content {
      bytes      = filebase64("${path.module}/branding/${asset.key}")
      category   = asset.value
      color_mode = "LIGHT" # settings.json forces light mode
      extension  = "SVG"
    }
  }

  # a v2 domain has no sign-in page without branding
  depends_on = [aws_cognito_user_pool_domain.main]
}
