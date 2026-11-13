terraform {
  required_version = ">= 1.5"
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 5.0" }
    random  = { source = "hashicorp/random", version = "~> 3.5" }
    null    = { source = "hashicorp/null", version = "~> 3.2" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }
}

# ---------------------------------------------------------------- Variables
variable "region" {
  type    = string
  default = "us-east-1"
}

variable "stage" {
  type    = string
  default = "uat"
}

variable "lambda_runtime" {
  type    = string
  default = "python3.12" # pip below builds wheels for this version
}

variable "vpc_id" {
  description = "Existing VPC to use. Leave null to use the default VPC."
  type        = string
  default     = null
}

variable "private_subnet_cidrs" {
  description = "Two new /24 ranges that must not overlap existing subnets in the VPC."
  type        = list(string)
  default     = ["172.31.200.0/24", "172.31.201.0/24"] # free range in a default VPC (172.31.0.0/16)
}

provider "aws" {
  region = var.region
}

locals {
  name           = "rds-postgres-db-provisioner"
  python_version = trimprefix(var.lambda_runtime, "python")
}

# ---------------------------------------------------------------- Network
# Only the VPC is pre-existing. Everything else below is dedicated.
data "aws_vpc" "this" {
  id      = var.vpc_id
  default = var.vpc_id == null ? true : null
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "private" {
  count                   = 2
  vpc_id                  = data.aws_vpc.this.id
  cidr_block              = var.private_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false

  tags = { Name = "${local.name}-private-${count.index + 1}" }
}

# Dedicated route table with only the implicit local route (no internet route).
resource "aws_route_table" "private" {
  vpc_id = data.aws_vpc.this.id
  tags   = { Name = "${local.name}-private" }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

locals {
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_security_group" "lambda" {
  name_prefix = "${local.name}-lambda-"
  vpc_id      = data.aws_vpc.this.id

  egress {
    description = "To RDS and the Secrets Manager endpoint (VPC-internal only)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [data.aws_vpc.this.cidr_block]
  }
}

resource "aws_security_group" "rds" {
  name_prefix = "${local.name}-rds-"
  vpc_id      = data.aws_vpc.this.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }
}

resource "aws_security_group" "endpoint" {
  name_prefix = "${local.name}-vpce-"
  vpc_id      = data.aws_vpc.this.id

  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }
}

# Lets the VPC-attached Lambda reach Secrets Manager without a NAT gateway.
resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = data.aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.subnet_ids
  security_group_ids  = [aws_security_group.endpoint.id]
  private_dns_enabled = true
}

# ---------------------------------------------------------------- RDS
resource "aws_db_subnet_group" "this" {
  name       = local.name
  subnet_ids = local.subnet_ids
}

resource "aws_db_parameter_group" "this" {
  name   = local.name
  family = "postgres16"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
}

resource "aws_db_instance" "this" {
  identifier        = local.name
  engine            = "postgres"
  engine_version    = "16"
  instance_class    = "db.t4g.micro" # cheapest current option
  allocated_storage = 20
  storage_type      = "gp2"
  storage_encrypted = true

  username                    = "postgres"
  manage_master_user_password = true # secret with {username,password} in Secrets Manager

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true
}

# ---------------------------------------------------------------- Packaging
resource "null_resource" "build_provisioner" {
  triggers = {
    code    = filesha256("${path.module}/lambda/provisioner/lambda_function.py")
    runtime = var.lambda_runtime
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      rm -rf "${path.module}/build/provisioner"
      mkdir -p "${path.module}/build/provisioner"
      pip install --no-cache-dir --only-binary=:all: \
        --platform manylinux2014_x86_64 --implementation cp \
        --python-version ${local.python_version} \
        --target "${path.module}/build/provisioner" psycopg2-binary
      cp "${path.module}/lambda/provisioner/lambda_function.py" "${path.module}/build/provisioner/"
    EOT
  }
}

data "archive_file" "provisioner" {
  type        = "zip"
  source_dir  = "${path.module}/build/provisioner"
  output_path = "${path.module}/build/provisioner.zip"
  depends_on  = [null_resource.build_provisioner]
}

data "archive_file" "authorizer" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/authorizer"
  output_path = "${path.module}/build/authorizer.zip"
}

# ---------------------------------------------------------------- Log groups
resource "aws_cloudwatch_log_group" "provisioner" {
  name              = "/aws/lambda/${local.name}"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "authorizer" {
  name              = "/aws/lambda/${local.name}-authorizer"
  retention_in_days = 7
}

# ---------------------------------------------------------------- Provisioner Lambda
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "provisioner" {
  name               = "${local.name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "provisioner_vpc" {
  role       = aws_iam_role.provisioner.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "provisioner_secret" {
  name = "postgres-rds-secret-access"
  role = aws_iam_role.provisioner.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadRDSAdminSecret"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_db_instance.this.master_user_secret[0].secret_arn
    }]
  })
}

resource "aws_lambda_function" "provisioner" {
  function_name    = local.name
  role             = aws_iam_role.provisioner.arn
  runtime          = var.lambda_runtime
  handler          = "lambda_function.lambda_handler"
  architectures    = ["x86_64"]
  filename         = data.archive_file.provisioner.output_path
  source_code_hash = data.archive_file.provisioner.output_base64sha256
  memory_size      = 256
  timeout          = 25 # HTTP API integrations cap at 30s

  vpc_config {
    subnet_ids         = local.subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      DB_SECRET_ARN = aws_db_instance.this.master_user_secret[0].secret_arn
      DB_HOST       = aws_db_instance.this.address
      DB_PORT       = "5432"
      DB_NAME       = "postgres"
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.provisioner_vpc,
    aws_iam_role_policy.provisioner_secret,
    aws_vpc_endpoint.secretsmanager,
    aws_cloudwatch_log_group.provisioner,
  ]
}

# ---------------------------------------------------------------- Token authorizer Lambda
resource "random_password" "api_token" {
  length  = 40
  special = false
}

resource "aws_iam_role" "authorizer" {
  name               = "${local.name}-authorizer-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "authorizer_basic" {
  role       = aws_iam_role.authorizer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "authorizer" {
  function_name    = "${local.name}-authorizer"
  role             = aws_iam_role.authorizer.arn
  runtime          = var.lambda_runtime
  handler          = "lambda_function.lambda_handler"
  filename         = data.archive_file.authorizer.output_path
  source_code_hash = data.archive_file.authorizer.output_base64sha256
  memory_size      = 128
  timeout          = 5

  environment {
    variables = {
      API_TOKEN = random_password.api_token.result
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.authorizer_basic,
    aws_cloudwatch_log_group.authorizer,
  ]
}

# ---------------------------------------------------------------- API Gateway (HTTP API)
resource "aws_apigatewayv2_api" "this" {
  name          = "postgres-db-creator-lambda-api-gw"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "provisioner" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.provisioner.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_authorizer" "token" {
  api_id                            = aws_apigatewayv2_api.this.id
  name                              = "bearer-token"
  authorizer_type                   = "REQUEST"
  authorizer_uri                    = aws_lambda_function.authorizer.invoke_arn
  authorizer_payload_format_version = "2.0"
  enable_simple_responses           = true
  identity_sources                  = ["$request.header.Authorization"]
  authorizer_result_ttl_in_seconds  = 0 # no caching, so token changes apply immediately
}

resource "aws_apigatewayv2_route" "create_db" {
  api_id             = aws_apigatewayv2_api.this.id
  route_key          = "POST /postgres-db-creator"
  target             = "integrations/${aws_apigatewayv2_integration.provisioner.id}"
  authorization_type = "CUSTOM"
  authorizer_id      = aws_apigatewayv2_authorizer.token.id
}

resource "aws_apigatewayv2_stage" "this" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = var.stage
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw_provisioner" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.provisioner.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_authorizer" {
  statement_id  = "AllowAPIGatewayInvokeAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/authorizers/${aws_apigatewayv2_authorizer.token.id}"
}

# ---------------------------------------------------------------- Outputs
output "api_url" {
  value = "${aws_apigatewayv2_stage.this.invoke_url}/postgres-db-creator"
}

output "api_token" {
  value     = random_password.api_token.result
  sensitive = true
}

output "rds_endpoint" {
  value = aws_db_instance.this.address
}
