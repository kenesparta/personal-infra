locals {
  # Written into the tags of every migrated resource and therefore present in
  # state. Any change here is a diff on ~20 resources — see variables.tf.
  common_tags = {
    Project     = var.project
    Owner       = var.owner
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  zone_id = aws_route53_zone.kenespartadev.zone_id

  cdn_main_bucket = "cdn.${var.primary_dns}"

  # The Discord app's legal pages (§5.11). A static site, NOT the bot — which
  # stays headless (§5.3 rev 2.10). Covered by the wildcard ACM cert, so it must
  # stay under kenesparta.dev.
  cnayp_bot_site_domain = "cnayp-bot.${var.primary_dns}"

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
  origin_projects = { for n, p in local.projects : n => p if can(p.origin) }

  # Every project needing its OWN CloudFront distribution and alias records.
  # blog is EXCLUDED — it keeps the migrated singleton in cloudfront.tf, whose
  # address must not change (AD-9).
  edge_projects = { for n, p in local.projects : n => p if n != "blog" && can(p.hostname) }
}
