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

# ── cnayp-discord-bot → the legal-pages bucket (spec §5.11) ──────────────────
# A SEPARATE role, deliberately, rather than a fourth `sub` on the role above.
# That role carries cdn-bucket-write-policy, so adding the bot's repository to
# its trust policy would hand a Discord bot's CI write access to the CV and the
# blog's assets — an authorization decision made invisibly, by editing a list of
# repository names. One role, one repository, one bucket.
#
# The role is assumed over OIDC and issues no key: there is nothing to store in
# GitHub beyond the ARN, and nothing to rotate. Same reasoning as AD-10/G5 —
# a long-lived secret avoided rather than protected.
resource "aws_iam_role" "github_actions_cnayp_bot_site" {
  name = "github-actions-cnayp-bot-site"
  path = "/github-actions/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCnaypBotRepoOIDC"
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          # TAG-scoped only: the site publishes on a release tag, never on a push
          # to main. A pull request from a fork runs with a `sub` of
          # `repo:...:pull_request`, which matches neither pattern, so an
          # untrusted PR cannot publish the site.
          #
          # Both spellings of the repository are listed because GitHub now issues
          # IMMUTABLE subject claims: the owner and repository carry their numeric
          # ids, as `kenesparta@8525741/cnayp-discord-bot@1333797062`. That is the
          # form actually presented today — a policy naming only the plain names
          # is denied, which is not obvious from the error, since STS reports a
          # claim mismatch as a flat "Not authorized to perform
          # sts:AssumeRoleWithWebIdentity". The ids are the point of the format:
          # deleting this repository and recreating one with the same name yields
          # a different id, so it cannot inherit this trust. The classic spelling
          # is kept so the role survives the claim format changing back.
          StringLike = {
            "token.actions.githubusercontent.com:sub" = [
              "repo:kenesparta@8525741/cnayp-discord-bot@1333797062:ref:refs/tags/*",
              "repo:kenesparta/cnayp-discord-bot:ref:refs/tags/*",
            ]
          }
        }
      }
    ]
  })

  tags = merge(
    local.common_tags,
    {
      Name = "github-actions-cnayp-bot-site"
      # No apostrophe. IAM tag VALUES are validated against
      # [\p{L}\p{Z}\p{N}_.:/=+\-@]* — letters, digits, separators and that
      # punctuation set only. An apostrophe is in none of those classes and
      # CreateRole rejects the whole call, which is why this reads "the legal
      # pages for X" rather than "X's legal pages". S3 and CloudFront tags are
      # more permissive; IAM is the one that bites.
      Description = "Publishes the legal pages for cnayp-discord-bot to ${local.cnayp_bot_site_domain}"
    }
  )
}

resource "aws_iam_role_policy" "github_actions_cnayp_bot_site" {
  name = "cnayp-bot-site-publish-policy"
  role = aws_iam_role.github_actions_cnayp_bot_site.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # No s3:PutObjectAcl, unlike the CDN policy above: the bucket blocks
        # public ACLs entirely and OAC is the read path, so the ability to set
        # one would be a way to make a mistake, not a capability that is needed.
        Sid    = "AllowSitePublish"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.cnayp_bot_site.arn}/*"
      },
      {
        # `aws s3 sync --delete` needs to enumerate before it can diff.
        Sid    = "AllowSiteList"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = aws_s3_bucket.cnayp_bot_site.arn
      },
      {
        # The edge holds an object for at most an hour on its own (§5.11), so
        # this is not what makes an update land — it is what makes a correction
        # to a published legal document land in seconds instead of minutes.
        # Scoped to this one distribution.
        Sid      = "AllowSiteInvalidation"
        Effect   = "Allow"
        Action   = "cloudfront:CreateInvalidation"
        Resource = aws_cloudfront_distribution.cnayp_bot_site.arn
      }
    ]
  })
}
