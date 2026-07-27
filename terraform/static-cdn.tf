# ── MIGRATED from kenesparta.dev/tf/static-cdn.tf ────────────────────────────
# cdn.kenesparta.dev — S3 + CloudFront for static assets. Entirely independent
# of the host migration; nothing here changes in any phase. The typst-resume
# repo writes to this bucket via the CI role (iam.tf).

resource "aws_s3_bucket" "cdn_bucket" {
  bucket = local.cdn_main_bucket
}

resource "aws_s3_bucket_public_access_block" "cdn_bucket" {
  bucket = aws_s3_bucket.cdn_bucket.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "cdn_bucket_policy" {
  bucket = aws_s3_bucket.cdn_bucket.id

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
        Resource = "${aws_s3_bucket.cdn_bucket.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.cdn_distribution.arn
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.cdn_bucket]
}

resource "aws_cloudfront_origin_access_control" "cdn_oac" {
  name                              = "cdn-kenesparta-dev-oac"
  description                       = "OAC for cdn.kenesparta.dev"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_response_headers_policy" "cors_policy" {
  name    = "cdn-cors-policy"
  comment = "CORS + default browser cache for stable-name CDN objects"

  # spec §4, G19 — the distribution's TTLs govern only CloudFront's edge cache;
  # browsers follow this header. Default behavior only: stable-name objects
  # (the CV, img/*) are overwritten in place, so the fallback stays short and
  # override stays off — deliberate per-object Cache-Control metadata wins
  # (the typst-resume CI uploads the CV with max-age=3600).
  custom_headers_config {
    items {
      header   = "Cache-Control"
      value    = "public, max-age=300"
      override = false
    }
  }

  cors_config {
    access_control_allow_credentials = false

    access_control_allow_headers {
      items = ["*"]
    }

    access_control_allow_methods {
      items = ["GET", "HEAD", "OPTIONS"]
    }

    access_control_allow_origins {
      items = ["https://${var.primary_dns}", "*"]
    }

    origin_override = true
  }
}

# spec §4, G19 — year-long browser caching for filename-versioned, write-once
# paths only (fonts/*, blog/*). `immutable` cannot be invalidated out of a
# browser, so nothing overwritten in place may ever be served from a behavior
# using this policy — replacing an asset here means renaming it.
resource "aws_cloudfront_response_headers_policy" "immutable_policy" {
  name    = "cdn-immutable-policy"
  comment = "CORS + immutable browser cache for versioned CDN paths"

  custom_headers_config {
    items {
      header   = "Cache-Control"
      value    = "public, max-age=31536000, immutable"
      override = true
    }
  }

  cors_config {
    access_control_allow_credentials = false

    access_control_allow_headers {
      items = ["*"]
    }

    access_control_allow_methods {
      items = ["GET", "HEAD", "OPTIONS"]
    }

    access_control_allow_origins {
      items = ["https://${var.primary_dns}", "*"]
    }

    origin_override = true
  }
}

resource "aws_cloudfront_distribution" "cdn_distribution" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "CDN for cdn.kenesparta.dev"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

  aliases = [local.cdn_main_bucket]

  origin {
    domain_name              = aws_s3_bucket.cdn_bucket.bucket_regional_domain_name
    origin_id                = "S3-cdn.kenesparta.dev"
    origin_access_control_id = aws_cloudfront_origin_access_control.cdn_oac.id
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-cdn.kenesparta.dev"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    response_headers_policy_id = aws_cloudfront_response_headers_policy.cors_policy.id

    # min_ttl 0 lets an object's own Cache-Control govern the edge too — with
    # the old 86400 floor an in-place CV overwrite stayed edge-stale for a day
    # despite its max-age=3600 (G19).
    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 300
    max_ttl                = 86400
    compress               = true
  }

  # spec §4, G19 — only these paths carry the immutable policy; both are
  # filename-versioned or write-once, and a stable-name object must never
  # move under them.
  ordered_cache_behavior {
    path_pattern     = "fonts/*"
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-cdn.kenesparta.dev"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    response_headers_policy_id = aws_cloudfront_response_headers_policy.immutable_policy.id

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 86400
    default_ttl            = 86400
    max_ttl                = 86400
    compress               = true
  }

  ordered_cache_behavior {
    path_pattern     = "blog/*"
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-cdn.kenesparta.dev"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    response_headers_policy_id = aws_cloudfront_response_headers_policy.immutable_policy.id

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 86400
    default_ttl            = 86400
    max_ttl                = 86400
    compress               = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.kenesparta_cert.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = merge(
    local.common_tags,
    {
      Name = local.cdn_main_bucket
    }
  )
}

resource "aws_route53_record" "kenesparta_cdn" {
  zone_id = local.zone_id
  name    = "cdn.${var.primary_dns}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.cdn_distribution.domain_name
    zone_id                = aws_cloudfront_distribution.cdn_distribution.hosted_zone_id
    evaluate_target_health = false
  }
}
