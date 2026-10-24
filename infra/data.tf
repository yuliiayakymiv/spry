# Things Terraform READS but does not own: the Lab 2 stack created by infra/aws/0*.sh.
# Same lookups the old deploy scripts did with the AWS CLI, now visible in every plan.

data "aws_vpc" "default" {
  default = true
}

# 01-network.sh: the default VPC's default-for-az subnets.
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# Those subnets use the main route table; the S3 gateway endpoint adds a route to it.
data "aws_route_table" "main" {
  vpc_id = data.aws_vpc.default.id
  filter {
    name   = "association.main"
    values = ["true"]
  }
}

# The API tasks' group; RDS already accepts 5432 from it, so the report builder joins it.
data "aws_security_group" "ecs" {
  vpc_id = data.aws_vpc.default.id
  name   = "${var.project_name}-ecs"
}

# 02-database.sh. Note: the value ends up in the Terraform state and in the builder's
# environment (as before, in the CloudFormation parameters). The state is in HCP Terraform.
data "aws_ssm_parameter" "database_url" {
  name = "/${var.project_name}/DATABASE_URL"
}

# The image the API runs right now. Both image Lambdas start from it; later image updates
# come from `make lambda-images` (the application road), not from Terraform.
data "aws_ecs_service" "api" {
  service_name = var.ecs_service
  cluster_arn  = "arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:cluster/${var.ecs_cluster}"
}

data "aws_ecs_container_definition" "api" {
  task_definition = data.aws_ecs_service.api.task_definition
  container_name  = var.container_name
}

locals {
  account_id    = data.aws_caller_identity.current.account_id
  backend_image = data.aws_ecs_container_definition.api.image
}
