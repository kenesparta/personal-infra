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
  domains = {
    (var.primary_dns) = {
      zone_id         = aws_route53_zone.kenespartadev.zone_id
      certificate_arn = aws_acm_certificate.kenesparta_cert.arn
    }
    (var.auruming_dns) = {
      zone_id         = aws_route53_zone.auruming.zone_id
      certificate_arn = aws_acm_certificate.auruming.arn
    }
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
