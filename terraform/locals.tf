locals {
  # Written into the tags of every migrated resource and therefore present in
  # state. Any change here is a diff on ~20 resources — see variables.tf.
  common_tags = {
    Project     = var.project
    Owner       = var.owner
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  # kenesparta.dev's zone. Still here, still correct, and still what the
  # kenesparta.dev-ONLY resources use: that certificate's validation records,
  # the Proton mail and Discord records, the CDN and the legal-pages site. The
  # per-PROJECT fan-out no longer uses it — see local.domains (AD-13).
  zone_id = aws_route53_zone.kenespartadev.zone_id

  # ── The domain seam (AD-13, spec §5.12, rev 2.12) ──────────────────────────
  # Keyed by REGISTERED domain, which is what `domain:` in projects.yml names.
  # Two hard-coded references used to tie the generic per-project fan-out to one
  # domain — the zone for its records and the ARN for its certificate — and both
  # were lookups, not structure. This map replaces them.
  #
  # It REFERENCES resources declared longhand in dns.tf / dns-auruming.tf and
  # acm.tf / acm-auruming.tf; it does not own them. Folding those into a
  # for_each over this map is the clean end state for a greenfield repo and was
  # rejected here (AD-13): it renames a DNSSEC-signed zone whose recreation
  # costs mail delivery (C9, G10) and two KMS keys that enter an unshortenable
  # 7-day deletion window, in exchange for making a fourth domain marginally
  # cheaper to add.
  #
  # Adding a domain: one zone file, one certificate file, one entry here.
  # kecc.link is deliberately ABSENT — it hosts no project and has no
  # certificate, so it has nothing to look up.
  #
  # rev 2.18 adds the status bucket (§5.15). It belongs here for the same reason
  # the certificate does: a project's branded 5xx page must come out of ITS
  # registered domain's bucket, and `domain:` is the only thing that says which.
  domains = {
    (var.primary_dns) = {
      zone_id              = aws_route53_zone.kenespartadev.zone_id
      certificate_arn      = aws_acm_certificate.kenesparta_cert.arn
      status_bucket_domain = aws_s3_bucket.status_pages.bucket_regional_domain_name
      status_oac_id        = aws_cloudfront_origin_access_control.status_pages.id
    }
    (var.auruming_dns) = {
      zone_id              = aws_route53_zone.auruming.zone_id
      certificate_arn      = aws_acm_certificate.auruming.arn
      status_bucket_domain = aws_s3_bucket.status_pages_auruming.bucket_regional_domain_name
      status_oac_id        = aws_cloudfront_origin_access_control.status_pages_auruming.id
    }
  }

  # ── Status pages (§5.15) ───────────────────────────────────────────────────
  # Every PUBLIC hostname mapped to the registered domain whose bucket holds its
  # page. `blog` is deliberately not in local.edge_projects — it kept the
  # migrated singleton distribution (AD-9, G10) — so this reads local.projects
  # and filters on `hostname`, which is exactly the ingress-set marker (§5.3).
  status_pages = {
    for n, p in local.projects : p.hostname => p.domain if can(p.hostname)
  }

  # Which distributions each status bucket must grant OAC reads to. Data-driven
  # rather than hard-coded project keys: adding a project to projects.yml must
  # not require remembering to widen a bucket policy by hand.
  status_distribution_arns = {
    for d in keys(local.domains) : d => concat(
      d == local.projects["blog"].domain ? [aws_cloudfront_distribution.app.arn] : [],
      [for n, p in local.edge_projects : aws_cloudfront_distribution.project[n].arn if p.domain == d]
    )
  }

  cdn_main_bucket = "cdn.${var.primary_dns}"

  # The Discord app's legal pages (§5.11). A static site, NOT the bot — which
  # stays headless (§5.3 rev 2.10). Covered by the wildcard ACM cert, so it must
  # stay under kenesparta.dev.
  cnayp_bot_site_domain = "cnayp-bot.${var.primary_dns}"

  # Static asset CDN for the second registered domain (§5.13). The hostname
  # lives in auruming.com's zone and rides its wildcard certificate; the BUCKET
  # name is unrelated and deliberately undotted (see var.auruming_cdn_bucket_name).
  auruming_cdn_domain = "cdn.${var.auruming_dns}"

  # Single source of truth shared with Ansible (spec §5.3). Keyed by name so
  # for_each is stable when the list is reordered.
  #
  # Entries are heterogeneous on purpose — a headless project carries no
  # hostname/origin/port (§5.3 rev 2.10). That is safe here: yamldecode yields
  # an object per entry and this for-expression keeps them as distinct object
  # types, so `for_each = local.projects` is fine (verified) and only an
  # expression that READS a missing attribute would fail. Hence the two subsets
  # below rather than `each.value.hostname` guarded at each use site.
  projects = { for p in yamldecode(file("${path.module}/../projects.yml")).projects : p.name => p }

  # Every project Caddy fronts. blog is INCLUDED: the origin A record is what
  # makes the name resolve directly to the instance, without which Caddy cannot
  # answer the HTTP-01 challenge for it (AD-8).
  #
  # Every member is guaranteed to carry `domain` too: the ingress set is
  # all-four-or-none (§5.3 rev 2.12), so `local.domains[p.domain]` below is safe
  # to read unguarded. An unknown domain fails the plan on the lookup; a
  # domain that is known but WRONG applies cleanly and never resolves (G24).
  origin_projects = { for n, p in local.projects : n => p if can(p.origin) }

  # Every project needing its OWN CloudFront distribution and alias records.
  # blog is EXCLUDED — it keeps the migrated singleton in cloudfront.tf, whose
  # address must not change (AD-9).
  edge_projects = { for n, p in local.projects : n => p if n != "blog" && can(p.hostname) }
}
