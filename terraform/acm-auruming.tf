# ── auruming.com certificate (spec §5.12, AD-13, rev 2.12) ───────────────────
# Its own certificate, NOT two more SANs on aws_acm_certificate.kenesparta_cert.
# ACM revalidates every name on a certificate at renewal, so sharing one would
# make the blog's certificate depend on a registrar account for an unrelated
# domain — and a SAN change is a full reissue and revalidation of the existing
# names, on a live HSTS-preloaded domain (G7). AD-13 has the rest.
#
# Apex + wildcard, matching acm.tf, so further projects under auruming.com need
# no certificate work at the edge.
#
# Like the kenesparta.dev certificate, this can never be installed on the
# Lightsail instance: standard ACM public certs are non-exportable (G2). The
# host gets its own Let's Encrypt certificate for origin.auruming.com — which
# draws on auruming.com's OWN 50-per-week budget, since Let's Encrypt limits are
# per registered domain (G8). That independence is a real benefit of AD-13:
# iterating on this vhost cannot lock out kenesparta.dev's origins.

resource "aws_acm_certificate" "auruming" {
  domain_name               = var.auruming_dns
  subject_alternative_names = ["*.${var.auruming_dns}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(
    local.common_tags,
    {
      Name = var.auruming_dns
    }
  )
}

# G23 — THIS RESOURCE IS THE ONE THAT BLOCKS. It polls until the CNAME below is
# publicly resolvable, and nothing under auruming.com resolves publicly until
# Namecheap delegates to this zone's nameservers. Run a full `terraform apply`
# before that delegation and it sits here for its whole timeout and then fails,
# leaving the zone, the certificate request and the distribution created.
#
# The documented order is:
#   1. make dns/auruming-zone   -> creates the zone alone (a targeted apply)
#   2. make dns/auruming        -> paste the four nameservers into Namecheap
#   3. dig NS auruming.com      -> wait until it answers with them
#   4. make plan && make apply  -> this validates, and the estate completes
resource "aws_acm_certificate_validation" "auruming" {
  certificate_arn         = aws_acm_certificate.auruming.arn
  validation_record_fqdns = [for record in aws_route53_record.auruming_cert_validation : record.fqdn]

  timeouts {
    # Shorter than the 45-minute default. The only reason this ever runs long is
    # a delegation that has not landed, and in that case failing sooner is
    # strictly better — the fix is at the registrar, not here, and a shorter
    # wait makes the retry loop tolerable.
    create = "20m"
  }
}

# The apex and the wildcard validate through the SAME DNS record: ACM emits one
# validation option per name, but for `x` + `*.x` both carry an identical
# `_<hash>.auruming.com` CNAME (verified on the kenesparta.dev certificate,
# whose two instances share one fqdn).
#
# Keying the for_each on `domain_name` therefore yields TWO instances managing
# ONE Route 53 record — it does not deduplicate them. `allow_overwrite = true`
# is what makes that benign rather than a "record already exists" failure, and
# it is load-bearing for exactly this reason, not merely defensive.
#
# Keying on `resource_record_name` instead would collapse the pair to a single
# instance. It is not done here purely for consistency: this is verbatim the
# shape of acm.tf, which has held the live certificate through the migration, and
# one proven pattern beats two similar ones.
resource "aws_route53_record" "auruming_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.auruming.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = aws_route53_zone.auruming.zone_id
}
