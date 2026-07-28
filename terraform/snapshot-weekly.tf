# ── Weekly snapshots — spec §5.8 (rev 2.5) ───────────────────────────────────
# The AutoSnapshot add-on is daily-only, so it is disabled (main.tf) and the
# Sunday cadence is driven from the AWS side: EventBridge fires a Lambda that
# creates a manual snapshot and prunes to the newest KEEP. Runs entirely off
# the host — no credential on the box (G5). The snapshots are MANUAL ones:
# nothing but the prune step ever deletes them (G20).

data "archive_file" "weekly_snapshot" {
  type        = "zip"
  source_file = "${path.module}/lambda/weekly_snapshot.py"
  output_path = "${path.module}/lambda/weekly_snapshot.zip"
}

resource "aws_iam_role" "weekly_snapshot" {
  name = "${var.instance_name}-weekly-snapshot"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags
}

# Lightsail actions largely ignore resource-level ARNs, so the real scoping —
# "only names under the weekly prefix" — lives in the Lambda code (G20).
resource "aws_iam_role_policy" "weekly_snapshot" {
  name = "weekly-snapshot"
  role = aws_iam_role.weekly_snapshot.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Snapshots"
        Effect = "Allow"
        Action = [
          "lightsail:CreateInstanceSnapshot",
          "lightsail:GetInstanceSnapshots",
          "lightsail:DeleteInstanceSnapshot"
        ]
        Resource = "*"
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_lambda_function" "weekly_snapshot" {
  function_name    = "${var.instance_name}-weekly-snapshot"
  role             = aws_iam_role.weekly_snapshot.arn
  runtime          = "python3.13"
  handler          = "weekly_snapshot.handler"
  architectures    = ["arm64"]
  timeout          = 60
  filename         = data.archive_file.weekly_snapshot.output_path
  source_code_hash = data.archive_file.weekly_snapshot.output_base64sha256

  environment {
    variables = {
      INSTANCE_NAME   = aws_lightsail_instance.app.name
      SNAPSHOT_PREFIX = "${var.instance_name}-weekly-"
      KEEP            = "4"
    }
  }

  tags = local.common_tags
}

# Sundays 06:00 UTC — the same 01:00 GMT-5 hour the daily add-on used.
resource "aws_cloudwatch_event_rule" "weekly_snapshot" {
  name                = "${var.instance_name}-weekly-snapshot"
  description         = "Weekly Lightsail snapshot of ${var.instance_name} (spec §5.8)"
  schedule_expression = "cron(0 6 ? * SUN *)"

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "weekly_snapshot" {
  rule = aws_cloudwatch_event_rule.weekly_snapshot.name
  arn  = aws_lambda_function.weekly_snapshot.arn
}

resource "aws_lambda_permission" "weekly_snapshot" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.weekly_snapshot.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.weekly_snapshot.arn
}
