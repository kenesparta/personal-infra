# ── MIGRATED from kenesparta.dev/tf/cloudfront.tf ────────────────────────────
# Phase 6 (done): the origin is the instance's Caddy at origin.kenesparta.dev,
# gated by the X-Origin-Verify secret header (AD-8, G11). The apex ALIAS below
# never changed — the origin swap was the whole cutover, no DNS propagation.

# Lived in legacy.tf until Phase 7; moved here with its consumers. sops + age
# (SOPS_AGE_KEY_FILE), the OTHER secrets mechanism — do not conflate with
# Ansible Vault. ORIGIN_VERIFY_SECRET must equal vault_origin_secret (G13).
data "sops_file" "prod_secrets" {
  source_file = "${path.module}/../secrets/prod.enc.env"
  input_type  = "dotenv"
}

# spec §5.6 — every project's origin name resolves DIRECTLY to the instance:
# Caddy must answer HTTP-01 on it, and a name pointing at CloudFront cannot
# satisfy that challenge (AD-8, AD-4). local.origin_projects is the subset of
# projects.yml that declares an `origin`; a headless project has none and gets
# no record here (§5.3 rev 2.10).
resource "aws_route53_record" "origin" {
  for_each = local.origin_projects

  zone_id = local.zone_id
  name    = each.value.origin
  type    = "A"
  ttl     = 300
  records = [aws_lightsail_static_ip.app.ip_address]
}

# ── Edge telemetry headers (AD-12, spec §5.10) ───────────────────────────────
# The applications log who reads what (IP + geolocation) into CloudWatch
# (AD-11); both facts only exist at the edge, delivered as headers.

# Near-CachingDisabled semantics plus the geo headers. A cache policy, not the
# origin request policy, because cache-key values are automatically included
# in origin requests and the ORP cannot whitelist CloudFront-* headers without
# also forwarding the viewer's Host, which would break Caddy's per-project
# vhost routing (AD-8). CloudFront-Viewer-Address / -ASN are rejected in cache
# policies — the viewer IP travels via the true-client-ip function below.
#
# max_ttl is 1, not 0: CreateCachePolicy rejects any header whitelist once all
# three TTLs are 0 (spec §5.10 as-applied, 2026-08-01). min/default stay 0, so
# nothing is cached unless the origin volunteers a Cache-Control — then for at
# most one second. That formally enables caching, so Authorization rides the
# key (in-key it is guaranteed into origin requests, sidestepping CloudFront's
# special GET/HEAD treatment of it on caching-enabled behaviors) and query
# strings ride too (a one-second entry is keyed on the exact request, never
# shared geo-wide). Cookies stay out of the key; the ORP still forwards them.
resource "aws_cloudfront_cache_policy" "disabled_plus_geo" {
  name        = "kenesparta-caching-disabled-plus-geo"
  comment     = "CachingDisabled semantics + geo headers + Authorization to the origin (AD-12)"
  min_ttl     = 0
  default_ttl = 0
  max_ttl     = 1

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = false
    enable_accept_encoding_brotli = false

    headers_config {
      header_behavior = "whitelist"
      headers {
        items = [
          "Authorization",
          "CloudFront-Viewer-Country",
          "CloudFront-Viewer-Country-Region-Name",
          "CloudFront-Viewer-City",
        ]
      }
    }

    cookies_config {
      cookie_behavior = "none"
    }

    query_strings_config {
      query_string_behavior = "all"
    }
  }
}

# The viewer IP as an ordinary (spoof-proof: overwritten) viewer header —
# AWS's documented add-true-client-ip-header pattern. Free at this volume
# (2M invocations/month always-free tier).
resource "aws_cloudfront_function" "true_client_ip" {
  name    = "kenesparta-true-client-ip"
  runtime = "cloudfront-js-2.0"
  comment = "Injects true-client-ip so the origin sees the viewer IP (AD-12)"
  publish = true
  code    = file("${path.module}/true-client-ip.js")
}

# Forwards all viewer headers/cookies/query strings to the origin EXCEPT Host,
# so CloudFront presents the origin domain as Host (correct for a custom
# origin). Server functions (POST) and SSR need everything else.
data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

resource "aws_cloudfront_distribution" "app" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "kenesparta.dev -> instance origin (Caddy, GHCR image)"
  aliases         = [var.primary_dns]
  price_class     = "PriceClass_100"

  origin {
    origin_id   = "instance"
    domain_name = local.projects["blog"].origin

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    # G13 — byte-identical to vault_origin_secret (the Caddy comparison side).
    # Rotation order: this side first, then the vault, then `make configure`.
    custom_header {
      name  = "X-Origin-Verify"
      value = data.sops_file.prod_secrets.data["ORIGIN_VERIFY_SECRET"]
    }
  }

  default_cache_behavior {
    target_origin_id         = "instance"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = aws_cloudfront_cache_policy.disabled_plus_geo.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    compress                 = true

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.true_client_ip.arn
    }
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
      Name = "kenesparta-cloudfront"
    }
  )
}

# Historical rename off the old App Runner resource. Retained verbatim so the
# copied state produces no diff; it is a no-op now that the move has applied
# and can be deleted once Phase 0 is signed off.
moved {
  from = aws_route53_record.apprunner_main
  to   = aws_route53_record.apex_cloudfront
}

# The apex. THIS RECORD DOES NOT CHANGE during the migration — it is why the
# host cutover needs no DNS propagation wait.
resource "aws_route53_record" "apex_cloudfront" {
  zone_id = local.zone_id
  name    = var.primary_dns
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.app.domain_name
    zone_id                = "Z2FDTNDATAQYW2" # CloudFront's fixed global hosted zone id
    evaluate_target_health = false
  }
}

# ── Per-project distributions (spec §5.3 rev 2.3, AD-8) ──────────────────────
# One distribution per NON-blog project that declares a hostname — blog keeps
# the migrated singleton above, and a headless project (§5.3 rev 2.10) has no
# public name to alias. CloudFront routes by path, never by Host, so hostnames
# cannot share a distribution; per-distribution cost is zero (billing is per
# request/GB). All hostnames ride the wildcard ACM cert, so they must stay under
# kenesparta.dev.

resource "aws_cloudfront_distribution" "project" {
  for_each = local.edge_projects

  enabled         = true
  is_ipv6_enabled = true
  comment         = "${each.value.hostname} -> instance origin (Caddy, GHCR image)"
  aliases         = [each.value.hostname]
  price_class     = "PriceClass_100"

  origin {
    origin_id   = "instance"
    domain_name = each.value.origin

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    # G13 — byte-identical to vault_origin_secret. Same value for every
    # project: the gate distinguishes "came through CloudFront", not projects.
    custom_header {
      name  = "X-Origin-Verify"
      value = data.sops_file.prod_secrets.data["ORIGIN_VERIFY_SECRET"]
    }
  }

  default_cache_behavior {
    target_origin_id         = "instance"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = aws_cloudfront_cache_policy.disabled_plus_geo.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    compress                 = true

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.true_client_ip.arn
    }
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
      Name = "${each.key}-cloudfront"
    }
  )
}

resource "aws_route53_record" "project_hostname_a" {
  for_each = local.edge_projects

  zone_id = local.zone_id
  name    = each.value.hostname
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.project[each.key].domain_name
    zone_id                = "Z2FDTNDATAQYW2"
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "project_hostname_aaaa" {
  for_each = local.edge_projects

  zone_id = local.zone_id
  name    = each.value.hostname
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.project[each.key].domain_name
    zone_id                = "Z2FDTNDATAQYW2"
    evaluate_target_health = false
  }
}
