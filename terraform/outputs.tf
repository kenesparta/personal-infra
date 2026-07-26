# ── MIGRATED outputs ─────────────────────────────────────────────────────────
# Outputs live in state too, so a NEW output shows as a diff. These two are the
# only outputs the old state carries — keep this file to exactly them, or the
# Phase 0 gate (`make plan/phase0`, which must report "No changes") goes red for
# a cosmetic reason and stops telling you anything useful.
#
# Everything added by the migration goes in outputs-phase1.tf.

output "cloudfront_domain" {
  value       = aws_cloudfront_distribution.app.domain_name
  description = "CloudFront distribution domain (the apex aliases to this)."
}

output "lightsail_app_url" {
  value       = aws_lightsail_container_service.app.url
  description = "LEGACY (removed in Phase 7): default HTTPS domain of the container service."
}
