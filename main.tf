provider "aws" {
}

resource "random_password" "db_master_pass" {
  length           = 40
  special          = true
  min_special      = 5
  override_special = "!#$%^&*()-_=+[]{}<>:?"
}

resource "random_id" "id" {
  byte_length = 8
}

resource "aws_secretsmanager_secret" "db-pass" {
  name = "db-pass-${random_id.id.hex}"
}

resource "aws_secretsmanager_secret_version" "db-pass-val" {
  secret_id = aws_secretsmanager_secret.db-pass.id
  secret_string = jsonencode(
    {
      username = aws_rds_cluster.cluster.master_username
      password = aws_rds_cluster.cluster.master_password
      engine   = "mysql"
      host     = aws_rds_cluster.cluster.endpoint
    }
  )
}

resource "aws_rds_cluster" "cluster" {
  engine               = "aurora-postgresql"
  engine_mode          = "provisioned"
	engine_version       = "15.4"
  database_name        = "mydb"
  master_username      = "test"
  master_password      = random_password.db_master_pass.result
	storage_encrypted    = true
  enable_http_endpoint = true
  skip_final_snapshot  = true
	serverlessv2_scaling_configuration {
    max_capacity = 1.0
    min_capacity = 1.0
  }
}

resource "aws_rds_cluster_instance" "cluster_instance" {
  cluster_identifier = aws_rds_cluster.cluster.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.cluster.engine
  engine_version     = aws_rds_cluster.cluster.engine_version
}

resource "null_resource" "db_setup" {
  triggers = {
    file = filesha1("initial.sql")
  }
  provisioner "local-exec" {
    command = <<-EOF
			aws rds-data execute-statement --resource-arn "$DB_ARN" --database "postgres" --secret-arn "$SECRET_ARN" --sql "drop database if exists $DB_NAME with (force);"
			aws rds-data execute-statement --resource-arn "$DB_ARN" --database "postgres" --secret-arn "$SECRET_ARN" --sql "create database $DB_NAME;"
			while read line; do
				echo "$line"
				aws rds-data execute-statement --resource-arn "$DB_ARN" --database "$DB_NAME" --secret-arn "$SECRET_ARN" --sql "$line"
			done  < <(awk 'BEGIN{RS=";\n"}{gsub(/\n/,""); if(NF>0) {print $0";"}}' initial.sql)
			EOF
    environment = {
      DB_ARN     = aws_rds_cluster.cluster.arn
      DB_NAME    = aws_rds_cluster.cluster.database_name
      SECRET_ARN = aws_secretsmanager_secret.db-pass.arn
    }
    interpreter = ["bash", "-c"]
  }
	depends_on = [aws_rds_cluster_instance.cluster_instance]
}

resource "aws_iam_role" "appsync" {
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "appsync.amazonaws.com"
      },
      "Effect": "Allow"
    }
  ]
}
EOF
}

data "aws_iam_policy_document" "appsync" {
  statement {
    actions = [
      "rds-data:ExecuteStatement",
    ]
    resources = [
      aws_rds_cluster.cluster.arn,
    ]
  }
  statement {
    actions = [
      "secretsmanager:GetSecretValue",
    ]
    resources = [
      aws_secretsmanager_secret.db-pass.arn,
    ]
  }
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = [
      "arn:aws:logs:*:*:*"
    ]
  }
}

resource "aws_iam_role_policy" "appsync" {
  role   = aws_iam_role.appsync.id
  policy = data.aws_iam_policy_document.appsync.json
}

resource "aws_cloudwatch_log_group" "loggroup" {
  name              = "/aws/appsync/apis/${aws_appsync_graphql_api.appsync.id}"
  retention_in_days = 14
}

resource "aws_appsync_graphql_api" "appsync" {
  name                = "appsync_test"
  schema              = file("schema.graphql")
  authentication_type = "AWS_IAM"
  log_config {
    cloudwatch_logs_role_arn = aws_iam_role.appsync.arn
    field_log_level          = "ALL"
  }
}

resource "aws_appsync_datasource" "rds" {
  api_id           = aws_appsync_graphql_api.appsync.id
  name             = "rds"
  service_role_arn = aws_iam_role.appsync.arn
  type             = "RELATIONAL_DATABASE"
  relational_database_config {
    http_endpoint_config {
      db_cluster_identifier = aws_rds_cluster.cluster.arn
      aws_secret_store_arn  = aws_secretsmanager_secret.db-pass.arn
      database_name         = aws_rds_cluster.cluster.database_name
    }
  }
}

# resolvers
resource "aws_appsync_resolver" "Query_groupById" {
  api_id            = aws_appsync_graphql_api.appsync.id
  type              = "Query"
  field             = "groupById"
	runtime {
    name            = "APPSYNC_JS"
    runtime_version = "1.0.0"
  }
  data_source       = aws_appsync_datasource.rds.name
	code = <<EOF
import {util} from "@aws-appsync/utils";
import {sql, createPgStatement, toJsonObject} from '@aws-appsync/utils/rds';

export function request(ctx) {
  const query = sql`
SELECT * FROM "user_group" WHERE id = $${ctx.args.id}
  `;
  return createPgStatement(query);
}

export function response(ctx) {
	if (ctx.error) {
		return util.error(ctx.error.message, ctx.error.type);
	}
	return toJsonObject(ctx.result)[0][0];
}

EOF
}

resource "aws_appsync_resolver" "Group_users" {
  api_id            = aws_appsync_graphql_api.appsync.id
  type              = "Group"
  field             = "users"
	runtime {
    name            = "APPSYNC_JS"
    runtime_version = "1.0.0"
  }
  data_source       = aws_appsync_datasource.rds.name
	code = <<EOF
import {util} from "@aws-appsync/utils";
import {sql, createPgStatement, toJsonObject} from '@aws-appsync/utils/rds';

export function request(ctx) {
	return createPgStatement(sql`
		SELECT * FROM "user" WHERE group_id = $${ctx.source.id}
	`);
}

export function response(ctx) {
	if (ctx.error) {
		return util.error(ctx.error.message, ctx.error.type);
	}
	return toJsonObject(ctx.result)[0];
}

EOF
}

resource "aws_appsync_resolver" "User_group" {
  api_id            = aws_appsync_graphql_api.appsync.id
  type              = "User"
  field             = "group"
	runtime {
    name            = "APPSYNC_JS"
    runtime_version = "1.0.0"
  }
  data_source       = aws_appsync_datasource.rds.name
	code = <<EOF
import {util} from "@aws-appsync/utils";
import {sql, createPgStatement, toJsonObject} from '@aws-appsync/utils/rds';

export function request(ctx) {
	return createPgStatement(sql`
		SELECT * FROM "user_group" WHERE id = $${ctx.source.group_id}
	`);
}

export function response(ctx) {
	if (ctx.error) {
		return util.error(ctx.error.message, ctx.error.type);
	}
	return toJsonObject(ctx.result)[0][0];
}

EOF
}

resource "aws_appsync_resolver" "Mutation_addUser" {
  api_id            = aws_appsync_graphql_api.appsync.id
  type              = "Mutation"
  field             = "addUser"
	runtime {
    name            = "APPSYNC_JS"
    runtime_version = "1.0.0"
  }
  data_source       = aws_appsync_datasource.rds.name
	code = <<EOF
import {util} from "@aws-appsync/utils";
import {sql, createPgStatement, toJsonObject} from '@aws-appsync/utils/rds';

export function request(ctx) {
	return createPgStatement(
		sql`
			INSERT INTO "user" (id, name, group_id) VALUES ($${util.autoId()}, $${ctx.args.name}, $${ctx.args.groupId}) RETURNING *
		`,
	);
}

export function response(ctx) {
	if (ctx.error) {
		return util.error(ctx.error.message, ctx.error.type);
	}
	return toJsonObject(ctx.result)[0][0];
}

EOF
}

resource "aws_appsync_resolver" "Mutation_addGroup" {
  api_id            = aws_appsync_graphql_api.appsync.id
  type              = "Mutation"
  field             = "addGroup"
	runtime {
    name            = "APPSYNC_JS"
    runtime_version = "1.0.0"
  }
  data_source       = aws_appsync_datasource.rds.name
	code = <<EOF
import {util} from "@aws-appsync/utils";
import {sql, createPgStatement, toJsonObject} from '@aws-appsync/utils/rds';

export function request(ctx) {
	return createPgStatement(
		sql`
			INSERT INTO "user_group" (id, name) VALUES ($${util.autoId()}, $${ctx.args.name}) RETURNING *
		`,
	);
}

export function response(ctx) {
	if (ctx.error) {
		return util.error(ctx.error.message, ctx.error.type);
	}
	return toJsonObject(ctx.result)[0][0];
}

EOF
}
