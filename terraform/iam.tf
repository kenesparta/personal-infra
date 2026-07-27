# ── MIGRATED from kenesparta.dev/tf/iam-main.tf ──────────────────────────────
# PHASE 0 STATE: all five policies retained verbatim.
#
# Phase 7 deletes three of them. Going pull-based (AD-5) removes CI's need to
# touch AWS almost entirely: GHCR authenticates with the built-in GITHUB_TOKEN,
# nothing pushes to ECR, and no workflow runs `terraform apply`. What survives
# is the CDN bucket write used by the typst-resume repo — which is why that repo
# is in the trust policy below.
#
#   github_actions_ecr        -> DELETE in Phase 7 (no more ECR)
#   github_actions_lightsail  -> DELETE in Phase 7 (no more container service)
#   github_actions_tfstate    -> DELETE in Phase 7 (CI no longer runs terraform)
#   github_actions_s3         -> KEEP (typst-resume writes the CDN bucket)

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1b511abead59c6ce207077c0bf0e0043b1382612"
  ]

  tags = merge(
    local.common_tags,
    {
      Name = "github-actions-oidc-provider"
    }
  )
}

resource "aws_iam_role" "github_actions_deploy" {
  name = "github-actions-ecr-ecs-deploy"
  path = "/github-actions/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowGitHubActionsOIDC"
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = [
              "repo:kenesparta/kenesparta.dev:ref:refs/heads/main",
              "repo:kenesparta/kenesparta.dev:ref:refs/tags/*",
              "repo:kenesparta/typst-resume:ref:refs/heads/main",
              "repo:kenesparta/typst-resume:ref:refs/tags/*",
            ]
          }
        }
      }
    ]
  })

  tags = merge(
    local.common_tags,
    {
      Name        = "github-actions-ecr-ecs-deploy"
      Description = "Role for GitHub Actions to deploy to ECR and ECS"
    }
  )
}

# NOTE: the role name ("...ecr-ecs-deploy") predates both migrations and is kept
# so the AWS_ROLE_ARN secret / OIDC binding stay valid; renaming it changes the
# ARN. It will be doubly inaccurate after Phase 7 (no ECR, no ECS). Leave it.




# SURVIVES Phase 7 — typst-resume publishes to the CDN bucket.
resource "aws_iam_role_policy" "github_actions_s3" {
  name = "cdn-bucket-write-policy"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowS3BucketWrite"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectAcl",
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.cdn_bucket.arn}/*"
      },
      {
        Sid    = "AllowS3BucketList"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = aws_s3_bucket.cdn_bucket.arn
      }
    ]
  })
}
