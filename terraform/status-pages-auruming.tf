# ── Origin-failure pages: auruming.com (spec §5.15, rev 2.18) ────────────────
# auruming.com's own status bucket. A separate file and a separate bucket for
# the same reason it has its own zone, KSK, certificate and CDN bucket (§5.12):
# a diff that touches only *-auruming.tf is visibly not touching the estate that
# carries mail (G10). One bucket for both domains would have worked technically
# and would have made every future status-page change a diff across both.
#
# The mechanism, the traps and the reasoning all live in status-pages.tf — read
# that file first. This one is the second instance, not a second design. The
# shared cache policy (aws_cloudfront_cache_policy.status_page) is declared
# there and used by both.

resource "aws_s3_bucket" "status_pages_auruming" {
  bucket = "auruming-status-pages"

  tags = merge(
    local.common_tags,
    {
      Name = "auruming-status-pages"
    }
  )
}

resource "aws_s3_bucket_public_access_block" "status_pages_auruming" {
  bucket = aws_s3_bucket.status_pages_auruming.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "status_pages_auruming" {
  name                              = "auruming-status-pages-oac"
  description                       = "OAC for the auruming.com origin-failure pages"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_s3_bucket_policy" "status_pages_auruming" {
  bucket = aws_s3_bucket.status_pages_auruming.id

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
        Resource = "${aws_s3_bucket.status_pages_auruming.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = local.status_distribution_arns[var.auruming_dns]
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.status_pages_auruming]
}

resource "aws_s3_object" "status_pages_auruming" {
  for_each = {
    for host, domain in local.status_pages : host => host if domain == var.auruming_dns
  }

  bucket = aws_s3_bucket.status_pages_auruming.id
  key    = "__status/${each.key}/maintenance.html"
  source = "${path.module}/../status-pages/${each.key}/maintenance.html"

  content_type  = "text/html; charset=utf-8"
  cache_control = "public, max-age=300"
  etag          = filemd5("${path.module}/../status-pages/${each.key}/maintenance.html")

  tags = local.common_tags
}
