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

  # Single source of truth shared with Ansible (spec §5.3). Keyed by name so
  # for_each is stable when the list is reordered.
  projects = { for p in yamldecode(file("${path.module}/../projects.yml")).projects : p.name => p }
}
