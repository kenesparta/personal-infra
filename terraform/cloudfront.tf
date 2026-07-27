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
# satisfy that challenge (AD-8, AD-4). local.projects is the projects.yml map.
resource "aws_route53_record" "origin" {
  for_each = local.projects

  zone_id = local.zone_id
  name    = each.value.origin
  type    = "A"
  ttl     = 300
  records = [aws_lightsail_static_ip.app.ip_address]
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
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
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    compress                 = true
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
# One distribution per NON-blog project — blog keeps the migrated singleton
# above. CloudFront routes by path, never by Host, so hostnames cannot share a
# distribution; per-distribution cost is zero (billing is per request/GB). All
# hostnames ride the wildcard ACM cert, so they must stay under kenesparta.dev.

resource "aws_cloudfront_distribution" "project" {
  for_each = { for name, p in local.projects : name => p if name != "blog" }

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
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    compress                 = true
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
  for_each = { for name, p in local.projects : name => p if name != "blog" }

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
  for_each = { for name, p in local.projects : name => p if name != "blog" }

  zone_id = local.zone_id
  name    = each.value.hostname
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.project[each.key].domain_name
    zone_id                = "Z2FDTNDATAQYW2"
    evaluate_target_health = false
  }
}
