# ── Container log shipping — spec §5.9 (AD-11) ───────────────────────────────
# Each project container's stdout/stderr lands in /kenesparta/<name> via
# Docker's awslogs driver (deploy role). Groups are created HERE, never by the
# driver: driver-created groups have no retention and bill forever, which is
# why the writer below is not allowed to create them (G21).

resource "aws_cloudwatch_log_group" "project" {
  for_each = local.projects

  name = "/kenesparta/${each.key}"
  # The whole retention story — logs here are a debugging window, not an
  # archive. A container whose group is missing fails to START, so never
  # delete one of these while projects.yml still lists the project (G21).
  retention_in_days = 7

  tags = merge(
    local.common_tags,
    {
      Name = "/kenesparta/${each.key}"
    }
  )
}

# The awslogs driver runs inside dockerd, which cannot use the instance's
# metadata credentials — resource access covers exactly one bucket (G5) — so
# this user's key is the host's ONLY static AWS credential (G21). There is
# deliberately no aws_iam_access_key resource: its secret half is a plain
# computed attribute that would sit in state in cleartext, the same reason the
# bucket access key was never created (G5). Mint the key out of band and put
# it in Ansible Vault (spec §9.4):
#
#   aws iam create-access-key --user-name $(terraform output -raw logs_writer_user)
#
resource "aws_iam_user" "logs_writer" {
  name = "${var.instance_name}-logs-writer"

  tags = merge(
    local.common_tags,
    {
      Name = "${var.instance_name}-logs-writer"
    }
  )
}

# Scoped so a leaked key can do nothing but write noise into these groups:
# stream create + event put on /kenesparta/* only — no CreateLogGroup (G21),
# no reads, nothing outside the prefix.
resource "aws_iam_user_policy" "logs_writer" {
  name = "cloudwatch-logs-write"
  user = aws_iam_user.logs_writer.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteProjectLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = flatten([
          for g in aws_cloudwatch_log_group.project : [g.arn, "${g.arn}:*"]
        ])
      }
    ]
  })
}
