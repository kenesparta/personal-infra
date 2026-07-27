# ── MIGRATED outputs ─────────────────────────────────────────────────────────
# The one survivor of the old state's outputs (`lightsail_app_url` died with
# legacy.tf in Phase 7). Everything added by the migration goes in
# outputs-phase1.tf.

output "cloudfront_domain" {
  value       = aws_cloudfront_distribution.app.domain_name
  description = "CloudFront distribution domain (the apex aliases to this)."
}

