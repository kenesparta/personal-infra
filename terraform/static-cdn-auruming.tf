# ── cdn.auruming.com — static asset CDN (spec §5.13) ─────────────────────────
# Assets for the auruming.com site, served from S3 rather than by the container.
# Same reasoning as §5.11: bytes out of S3 cost no RAM against AD-1's budget,
# occupy none of C3's four service slots, and stay up when the instance does not.
#
# Shaped after static-cnayp-bot.tf, NOT static-cdn.tf. The older CDN's dotted
# bucket name and all-false public access block are INHERITED from the
# pre-migration estate — they are what that file happens to do, not the pattern
# to copy. Every difference is called out below.

# Undotted, unlike cdn.kenesparta.dev. A dotted bucket name puts extra labels
# into the S3 REST endpoint (auruming-cdn.s3.us-east-1.amazonaws.com vs
# cdn.auruming.com.s3.us-east-1.amazonaws.com), where the AWS wildcard covers
# only one label. Nobody sees this name — the public one is the alias below.
resource "aws_s3_bucket" "auruming_cdn" {
  bucket = var.auruming_cdn_bucket_name

  tags = merge(
    local.common_tags,
    {
      Name = local.auruming_cdn_domain
    }
  )
}

# All four true, unlike the older CDN bucket. OAC is the only read path, so a
# public ACL or public policy is never needed. block_public_policy can stay on:
# S3 judges a policy public only when it grants to an anonymous or `*` principal
# with no restricting condition, and the policy below names a service principal
# with a SourceArn condition.
resource "aws_s3_bucket_public_access_block" "auruming_cdn" {
  bucket = aws_s3_bucket.auruming_cdn.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Readable ONLY by this distribution — the SourceArn condition means a
# CloudFront distribution in another account cannot be pointed at this bucket.
# The depends_on is ordering, not decoration: the block must exist before the
# policy is put, or the two race on a fresh apply.
resource "aws_s3_bucket_policy" "auruming_cdn" {
  bucket = aws_s3_bucket.auruming_cdn.id

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
        Resource = "${aws_s3_bucket.auruming_cdn.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.auruming_cdn.arn
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.auruming_cdn]
}

resource "aws_cloudfront_origin_access_control" "auruming_cdn" {
  name                              = "auruming-cdn-oac"
  description                       = "OAC for ${local.auruming_cdn_domain}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# G19 — THERE IS DELIBERATELY NO IMMUTABLE POLICY IN THIS FILE.
#
# `fonts/*` and `blog/*` on cdn.kenesparta.dev carry
# `public, max-age=31536000, immutable`, and that is safe there only because
# those paths are filename-versioned and write-once. Creating the equivalent on
# an EMPTY CDN would commit a path prefix to a year-long, uninvalidatable
# browser cache before a single object has been published under it — a trap for
# whoever first uploads a stable-name file to `fonts/`.
#
# Instead: a 5-minute default with `override = false`, so a deliberate
# per-object Cache-Control set at upload time wins — at the browser (this
# header defers to it) and at the edge (min_ttl = 0 below). That is strictly
# more flexible than a path-scoped immutable behavior and has no cliff.
#
# Adding one later has a precondition, not just a decision: the path must be
# filename-versioned and its objects never overwritten in place. Rename to
# replace.
resource "aws_cloudfront_response_headers_policy" "auruming_cdn" {
  name    = "auruming-cdn-headers"
  comment = "CORS + short default browser cache for cdn.auruming.com (§5.13, G19)"

  # One DAY, not the five minutes §5.11's documents use. This bucket holds
  # images, video and similar media — assets that are replaced rarely and
  # deliberately, and whose cost of being re-fetched is measured in megabytes.
  # A day is long enough to be a real cache and short enough that a mistake
  # ages out on its own, which `immutable` would not.
  custom_headers_config {
    items {
      header = "Cache-Control"
      value  = "public, max-age=86400"
      # override = false is the load-bearing half. With it true, an object
      # uploaded with its own max-age would be silently overridden back to a day
      # — including a deliberately SHORT one on something being iterated on.
      override = false
    }
  }

  # Present, unlike §5.11's legal pages: these assets are fetched cross-origin
  # by pages on auruming.com. The legal pages are opened directly and need none.
  cors_config {
    access_control_allow_credentials = false

    access_control_allow_headers {
      items = ["*"]
    }

    access_control_allow_methods {
      items = ["GET", "HEAD", "OPTIONS"]
    }

    access_control_allow_origins {
      items = ["https://${var.auruming_dns}"]
    }

    origin_override = true
  }

  security_headers_config {
    content_type_options {
      override = true
    }
  }
}

resource "aws_cloudfront_distribution" "auruming_cdn" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "${local.auruming_cdn_domain} — static assets"
  # PriceClass_100 = North America + Europe + Israel, matching every other
  # distribution in this account and the cheapest tier (C1). NOTE for media:
  # it EXCLUDES South America, so a viewer in Lima is served from a North
  # American edge — it still works, it is just a longer first byte. Only
  # PriceClass_All adds South American edges; that is a cost decision, not a
  # correctness one, and it is a one-word change here.
  price_class = "PriceClass_100"
  aliases     = [local.auruming_cdn_domain]

  # §5.14 — additive, not a switch: HTTP/3 where the client supports it, HTTP/2
  # otherwise. Without this the CloudFront default is `http2` and no viewer ever
  # attempts QUIC. Unrelated to Caddy's 443/udp publish, which no viewer reaches.
  http_version = "http2and3"
  # No default_root_object: this is an asset bucket, not a site. A request for
  # `/` should 403 -> 404 rather than resolve to an index.html nobody uploaded.

  origin {
    domain_name              = aws_s3_bucket.auruming_cdn.bucket_regional_domain_name
    origin_id                = "s3-auruming-cdn"
    origin_access_control_id = aws_cloudfront_origin_access_control.auruming_cdn.id
  }

  # GET/HEAD/OPTIONS only — this serves bytes, it never accepts them. Byte-range
  # requests, which is how a browser seeks within a video, are handled by
  # CloudFront on GET automatically and need no configuration here.
  default_cache_behavior {
    target_origin_id           = "s3-auruming-cdn"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    viewer_protocol_policy     = "redirect-to-https"
    compress                   = true
    response_headers_policy_id = aws_cloudfront_response_headers_policy.auruming_cdn.id

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    # min_ttl = 0 lets an object's own Cache-Control govern the EDGE too. The
    # older CDN learned this the hard way: an 86400 floor kept an overwritten
    # file edge-stale for a day despite its own max-age=3600 (G19). Keeping the
    # floor at 0 is what makes a short per-object max-age actually work.
    #
    # A day by default, a year at most — the ceiling only ever applies to an
    # object that ASKS for more, so it is headroom for versioned media rather
    # than a policy imposed on anything.
    min_ttl     = 0
    default_ttl = 86400
    max_ttl     = 31536000
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Via the VALIDATION resource, not the certificate directly. On a from-zero
  # apply an ACM ARN is known before the certificate is usable, and CloudFront
  # rejects an unissued one; this orders the distribution after issuance. The
  # older static-* files reference their certificate directly — theirs has been
  # issued for years, so the distinction never surfaced there.
  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.auruming.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = merge(
    local.common_tags,
    {
      Name = local.auruming_cdn_domain
    }
  )
}

# In auruming.com's OWN zone (AD-13) — never local.zone_id, which means
# kenesparta.dev's zone.
resource "aws_route53_record" "auruming_cdn_a" {
  zone_id = aws_route53_zone.auruming.zone_id
  name    = local.auruming_cdn_domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.auruming_cdn.domain_name
    zone_id                = aws_cloudfront_distribution.auruming_cdn.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "auruming_cdn_aaaa" {
  zone_id = aws_route53_zone.auruming.zone_id
  name    = local.auruming_cdn_domain
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.auruming_cdn.domain_name
    zone_id                = aws_cloudfront_distribution.auruming_cdn.hosted_zone_id
    evaluate_target_health = false
  }
}

# NOTE: no IAM role publishes to this bucket. Which repository may write, on
# which refs, is an authorization decision and §5.11 records why those are made
# explicitly — one role, one repository, one bucket — rather than by appending a
# `sub` to a role that already carries write access somewhere else. Until such a
# role exists, uploads are a manual `aws s3 sync` under the SSO admin profile.
