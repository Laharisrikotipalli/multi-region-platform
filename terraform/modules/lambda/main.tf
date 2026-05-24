variable "primary_region" {
  type    = string
  default = "ap-southeast-1"
}

variable "replica_region" {
  type    = string
  default = "eu-west-1"
}

variable "replica_db_identifier" {
  type    = string
  default = "mr-postgres-replica-euw1"
}

variable "alert_email" {
  type    = string
  default = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.root}/../../../lambda/lambda_function.py"
  output_path = "${path.module}/lambda.zip"
}

resource "aws_iam_role" "lambda_role" {
  name = "promote-replica-lambda-role"
  tags = var.tags
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "lambda-rds-failover-policy"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["rds:DescribeDBInstances", "rds:PromoteReadReplica", "rds:ModifyDBInstance"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_lambda_function" "promote_replica" {
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  function_name    = "promote-replica"
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.11"
  role             = aws_iam_role.lambda_role.arn
  timeout          = 300
  tags             = var.tags
  environment {
    variables = {
      PRIMARY_REGION        = var.primary_region
      REPLICA_REGION        = var.replica_region
      REPLICA_DB_IDENTIFIER = var.replica_db_identifier
      SNS_ALERT_TOPIC_ARN   = aws_sns_topic.failover_alerts.arn
    }
  }
}

resource "aws_sns_topic" "failover_alerts" {
  name = "db-failover-alerts"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "email_alert" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.failover_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_sns_topic" "cw_alarm_topic" {
  name = "rds-primary-unhealthy"
  tags = var.tags
}

resource "aws_lambda_permission" "allow_sns" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.promote_replica.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.cw_alarm_topic.arn
}

resource "aws_sns_topic_subscription" "lambda_trigger" {
  topic_arn = aws_sns_topic.cw_alarm_topic.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.promote_replica.arn
}

resource "aws_cloudwatch_metric_alarm" "rds_unhealthy" {
  alarm_name          = "rds-primary-unhealthy"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_description   = "Primary RDS has no connections - may be down"
  tags                = var.tags
  dimensions          = { DBInstanceIdentifier = "mr-postgres-primary" }
  alarm_actions       = [aws_sns_topic.cw_alarm_topic.arn]
  ok_actions          = [aws_sns_topic.cw_alarm_topic.arn]
}

output "lambda_function_arn" {
  value = aws_lambda_function.promote_replica.arn
}

output "sns_topic_arn" {
  value = aws_sns_topic.cw_alarm_topic.arn
}
