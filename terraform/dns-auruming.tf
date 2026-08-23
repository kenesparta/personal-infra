# ── auruming.com — the second registered domain (spec §5.12, AD-13, rev 2.12) ─
# Its OWN zone, its OWN key-signing key and its OWN KMS key. Nothing is shared
# with kenesparta.dev: Route 53 attaches a KSK to exactly one zone, so there was
# never a sharing option to reject, but the property is the point — disabling
# signing here, or scheduling this KMS key for deletion, cannot reach the zone
# that carries mail (G10).
#
# A SEPARATE FILE from dns.tf on purpose. The two estates have independent
# lifecycles, and a file boundary is the cheapest way to make a diff that
# touches auruming.com visibly not touch kenesparta.dev.
#
# G23 — TERRAFORM DOES NOT OWN THE DELEGATION. This domain is registered at
# Namecheap, so the zone below is invisible to the internet until its four
# nameservers are pasted into the registrar by hand, and DNSSEC is not active
# for resolvers until the DS record is pasted in too. `terraform plan` is clean
# whether or not either has been done. The order, and why the DS goes LAST, is
# G23; `make dns/auruming` prints both values.

resource "aws_route53_zone" "auruming" {
  name = var.auruming_dns

  tags = merge(
    local.common_tags,
    {
      Name = "auruming-DNS"
    }
  )
}

# Signing is enabled the moment this applies, which is correct and safe on its
# own: a signed zone with no DS at the parent is served, and validated, exactly
# like an unsigned one. It is publishing the DS while this is absent or broken
# that takes the domain down (G23 step 6).
resource "aws_route53_hosted_zone_dnssec" "auruming" {
  hosted_zone_id = aws_route53_zone.auruming.id
  depends_on     = [aws_route53_key_signing_key.auruming]
}

resource "aws_route53_key_signing_key" "auruming" {
  name                       = "auruming"
  hosted_zone_id             = aws_route53_zone.auruming.id
  key_management_service_arn = aws_kms_key.auruming_key_dnssec.arn
  status                     = "ACTIVE"
}

# ECC_NIST_P256 / SIGN_VERIFY is not a preference — Route 53 DNSSEC accepts no
# other key spec, and the key must live in us-east-1 (it does; var.region).
# deletion_window_in_days is the MINIMUM AWS allows: a destroy here is a 7-day
# window that cannot be shortened, during which the zone cannot be re-signed
# with this key and the domain must have no DS published.
resource "aws_kms_key" "auruming_key_dnssec" {
  description              = "DNSSEC key-signing key for ${var.auruming_dns}"
  customer_master_key_spec = "ECC_NIST_P256"
  deletion_window_in_days  = 7
  key_usage                = "SIGN_VERIFY"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Allow Route53 DNSSEC Service"
        Effect = "Allow"
        Principal = {
          Service = "dnssec-route53.amazonaws.com"
        }
        Action = [
          "kms:DescribeKey",
          "kms:GetPublicKey",
          "kms:Sign",
        ]
        Resource = "*"
      },
      {
        Sid    = "Allow administration of the key"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      }
    ]
  })

  tags = merge(
    local.common_tags,
    {
      Name = "auruming-dnssec-ksk"
    }
  )
}

# NOTE: no mail records. auruming.com sends and receives no mail, so it has no
# MX, SPF, DKIM or DMARC (unlike kenesparta.dev — see dns-records.tf). If mail
# is ever added, a domain with no SPF/DMARC is a spoofing target: publish at
# minimum `v=spf1 -all` and `v=DMARC1; p=reject` to say so explicitly, rather
# than leaving the absence to be interpreted.
