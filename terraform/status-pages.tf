# ── Origin-failure pages: kenesparta.dev (spec §5.15, rev 2.18) ──────────────
# The page a visitor sees when CloudFront cannot get an answer out of Caddy.
# Before this file that was CloudFront's own "504 Gateway Timeout ERROR", AWS
# wordmark and all — seen live on auruming.com during the 2026-09-01 reboot.
#
# The whole design turns on ONE fact (G28): `response_page_path` is a URI that
# CloudFront re-resolves through its OWN cache behaviors, not a URL. Point it at
# a path served by the app origin and CloudFront answers a 504 by asking the
# origin that just timed out — and falls back to the generic page. So the page
# needs a second origin that is up when the instance is not, which is this
# bucket, wired into every app distribution as `status` behind /__status/*.
#
# Shaped after static-cnayp-bot.tf. Undotted name for the reason given there:
# a dotted bucket puts extra labels into the S3 REST endpoint where the
# wildcard certificate covers only one. Nobody sees this name.

resource "aws_s3_bucket" "status_pages" {
  bucket = "kenesparta-status-pages"

  tags = merge(
    local.common_tags,
    {
      Name = "kenesparta-status-pages"
    }
  )
}

# Not versioned, unlike the legal pages (§5.11). These carry no obligation and
# no history worth reconstructing; the authoritative copy is in git under
# terraform/status-pages/ and Terraform overwrites from it.
resource "aws_s3_bucket_public_access_block" "status_pages" {
  bucket = aws_s3_bucket.status_pages.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "status_pages" {
  name                              = "kenesparta-status-pages-oac"
  description                       = "OAC for the kenesparta.dev origin-failure pages"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# One statement listing every distribution of THIS domain. StringEquals against
# a list is an OR, so a project added to projects.yml widens this automatically
# through local.status_distribution_arns rather than needing a hand edit.
resource "aws_s3_bucket_policy" "status_pages" {
  bucket = aws_s3_bucket.status_pages.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontAccess"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.status_pages.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = local.status_distribution_arns[var.primary_dns]
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.status_pages]
}

# ── The pages themselves ─────────────────────────────────────────────────────
# Uploaded by Terraform, not CI (§5.15): a few KB that change roughly never and
# that MUST already exist before the outage that needs them. The key mirrors the
# repository path, and `__status/` is the prefix the ordered cache behavior
# matches — key and path_pattern must agree or the error page routes back to the
# default behavior and the dead origin (G28).
resource "aws_s3_object" "status_pages" {
  for_each = {
    for host, domain in local.status_pages : host => host if domain == var.primary_dns
  }

  bucket = aws_s3_bucket.status_pages.id
  key    = "__status/${each.key}/maintenance.html"
  source = "${path.module}/status-pages/${each.key}/maintenance.html"

  content_type = "text/html; charset=utf-8"

  # G19 IN REVERSE, exactly as in §5.11. A maintenance page is a stable name
  # overwritten in place and the entire point of editing one is that the next
  # visitor sees the new text, so `immutable` must never appear here. Five
  # minutes at the edge; the behavior's cache policy agrees.
  cache_control = "public, max-age=300"

  # Without this Terraform compares nothing and an edited page never uploads.
  etag = filemd5("${path.module}/status-pages/${each.key}/maintenance.html")

  tags = local.common_tags
}

# ── Shared by BOTH domains' status behaviors ─────────────────────────────────
# Declared once here rather than twice: a cache policy is account-global and
# there is nothing domain-specific in it. Short TTLs because editing a page and
# waiting an hour to see it is how these pages rot.
resource "aws_cloudfront_cache_policy" "status_page" {
  name        = "kenesparta-status-page"
  comment     = "Static origin-failure pages from S3 (spec §5.15)"
  min_ttl     = 0
  default_ttl = 300
  max_ttl     = 3600

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true

    headers_config {
      header_behavior = "none"
    }
    cookies_config {
      cookie_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
  }
}
