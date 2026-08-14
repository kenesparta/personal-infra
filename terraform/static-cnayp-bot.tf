# ── cnayp-bot.kenesparta.dev — the Discord app's legal pages (spec §5.11) ────
# Terms of Service and Privacy Policy. Discord requires both as publicly
# reachable URLs before an application can be verified or listed, and it fetches
# them itself.
#
# Deliberately NOT served by the bot. `cnayp_discord_bot` is headless (§5.3 rev
# 2.10); giving it these pages would buy it an origin hostname, a Caddy vhost
# and a Let's Encrypt certificate against the shared 50/week budget (G8), and
# would tie documents Discord fetches to the uptime of a bot process on a 2 GB
# box. S3 + CloudFront costs no RAM, occupies none of C3's four service slots,
# and stays up when the instance does not.
#
# Shaped after static-cdn.tf, with three deliberate differences — each below.

# Named WITHOUT dots, unlike cdn.kenesparta.dev (which inherited its name from
# the pre-migration estate) and like kenesparta-infra-backups. A dotted bucket
# name puts extra labels into the S3 REST endpoint, where the wildcard
# certificate covers only one; it is a class of TLS/SigV4 edge case worth not
# owning. Nobody sees this name — the public one is the CloudFront alias.
resource "aws_s3_bucket" "cnayp_bot_site" {
  bucket = "kenesparta-cnayp-bot-site"

  tags = merge(
    local.common_tags,
    {
      Name = local.cnayp_bot_site_domain
    }
  )
}

# Versioned, unlike the CDN bucket. These are legal documents: being able to
# show what the privacy policy said on a given date is the point, and it also
# means a bad `s3 sync --delete` from CI is recoverable rather than terminal.
# Four small HTML files — the storage cost is not a consideration.
resource "aws_s3_bucket_versioning" "cnayp_bot_site" {
  bucket = aws_s3_bucket.cnayp_bot_site.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Fully blocked, unlike the CDN bucket's all-false block (also inherited from
# the pre-migration estate). All four stay true INCLUDING block_public_policy:
# S3 judges a policy public only when it grants to an anonymous or `*` principal
# without a restricting condition, and the policy below names a service
# principal with a SourceArn condition. OAC is the only read path, so nothing
# here ever needs a public ACL or a public policy.
resource "aws_s3_bucket_public_access_block" "cnayp_bot_site" {
  bucket = aws_s3_bucket.cnayp_bot_site.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Readable ONLY by this distribution: the SourceArn condition means a CloudFront
# distribution in another account cannot be pointed at this bucket. The
# depends_on is ordering, not decoration — the block must exist before the
# policy is put, or the two race on a fresh apply.
resource "aws_s3_bucket_policy" "cnayp_bot_site" {
  bucket = aws_s3_bucket.cnayp_bot_site.id

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
        Resource = "${aws_s3_bucket.cnayp_bot_site.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.cnayp_bot_site.arn
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.cnayp_bot_site]
}

resource "aws_cloudfront_origin_access_control" "cnayp_bot_site" {
  name                              = "cnayp-bot-site-oac"
  description                       = "OAC for ${local.cnayp_bot_site_domain}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# G19 IN REVERSE, and the reason there is no immutable behavior anywhere in this
# file. `fonts/*` and `blog/*` on the CDN are filename-versioned and write-once,
# so a year-long immutable cache is safe there. A Terms of Service and a Privacy
# Policy are the opposite: stable names, overwritten in place, and the entire
# point of updating one is that people see the new text. `immutable` cannot be
# invalidated out of a browser — it would mean a reader keeps the superseded
# policy for a year with no way to reach them. Five minutes at the edge, one
# hour at most.
resource "aws_cloudfront_cache_policy" "cnayp_bot_site" {
  name        = "kenesparta-cnayp-bot-short-static"
  comment     = "5-minute cache for documents overwritten in place (§5.11, G19)"
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

resource "aws_cloudfront_response_headers_policy" "cnayp_bot_site" {
  name    = "cnayp-bot-site-headers"
  comment = "Baseline security headers for the legal pages (§5.11)"

  # No CORS block, unlike the CDN's policies: nothing cross-origin fetches these
  # pages. A person or Discord's crawler opens them directly.
  security_headers_config {
    content_type_options {
      override = true
    }

    frame_options {
      frame_option = "SAMEORIGIN"
      override     = true
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }

    # Redundant on a .dev name — the TLD is HSTS-preloaded (G7), so browsers
    # already refuse plaintext. Stated anyway because "the TLD covers it" is not
    # something a reviewer should have to know. include_subdomains is false:
    # there is nothing under this name to make promises about.
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = false
      preload                    = false
      override                   = true
    }
  }
}

resource "aws_cloudfront_distribution" "cnayp_bot_site" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${local.cnayp_bot_site_domain} — Discord app legal pages"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  aliases             = [local.cnayp_bot_site_domain]

  origin {
    domain_name              = aws_s3_bucket.cnayp_bot_site.bucket_regional_domain_name
    origin_id                = "s3-cnayp-bot-site"
    origin_access_control_id = aws_cloudfront_origin_access_control.cnayp_bot_site.id
  }

  default_cache_behavior {
    target_origin_id           = "s3-cnayp-bot-site"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    viewer_protocol_policy     = "redirect-to-https"
    compress                   = true
    cache_policy_id            = aws_cloudfront_cache_policy.cnayp_bot_site.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.cnayp_bot_site.id
  }

  # An S3 origin behind OAC answers a MISSING key with 403, not 404 — the
  # distribution is not granted s3:ListBucket, deliberately, so S3 will not
  # distinguish "absent" from "forbidden". Both map to one page so that a
  # mistyped link shows a page instead of raw S3 XML to someone Discord sent
  # here. `404.html` is therefore a REQUIRED part of the upload set, not a nicety
  # — CloudFront falls back to its own generic error page if it is missing.
  custom_error_response {
    error_code            = 403
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 60
  }

  custom_error_response {
    error_code            = 404
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 60
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # The same wildcard cert every other distribution uses (acm.tf). This is why
  # the name has to stay under kenesparta.dev, and why adding it costs no
  # certificate work at all.
  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.kenesparta_cert.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = merge(
    local.common_tags,
    {
      Name = local.cnayp_bot_site_domain
    }
  )
}

resource "aws_route53_record" "cnayp_bot_site_a" {
  zone_id = local.zone_id
  name    = local.cnayp_bot_site_domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.cnayp_bot_site.domain_name
    zone_id                = aws_cloudfront_distribution.cnayp_bot_site.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "cnayp_bot_site_aaaa" {
  zone_id = local.zone_id
  name    = local.cnayp_bot_site_domain
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.cnayp_bot_site.domain_name
    zone_id                = aws_cloudfront_distribution.cnayp_bot_site.hosted_zone_id
    evaluate_target_health = false
  }
}
