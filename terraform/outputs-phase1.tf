# ── Outputs added by the migration ───────────────────────────────────────────
# Separate from outputs.tf so `make plan/phase0` can move this file and main.tf
# aside and plan the migrated config alone. Anything here referencing a Phase 1
# resource MUST stay out of outputs.tf.

output "static_ip" {
  value       = aws_lightsail_static_ip.app.ip_address
  description = "Host IPv4. Consumed by `make inventory` to generate the Ansible inventory."
}

output "instance_name" {
  value       = aws_lightsail_instance.app.name
  description = "For `aws lightsail` CLI calls."
}

output "ssh_command" {
  value       = "ssh -i ~/.ssh/personal-infra ubuntu@${aws_lightsail_static_ip.app.ip_address}"
  description = "Convenience. Assumes the private key sits beside the .pub referenced by ssh_public_key_path."
}

output "backup_bucket" {
  value       = aws_lightsail_bucket.backups.name
  description = "pg_dump destination. Set as backup_bucket in ansible/group_vars/all.yml — Ansible does not read Terraform state."
}

output "cdn_domain" {
  value       = aws_cloudfront_distribution.cdn_distribution.domain_name
  description = "cdn.kenesparta.dev distribution. Unchanged by the migration, but not previously exported."
}

output "logs_writer_user" {
  value       = aws_iam_user.logs_writer.name
  description = "IAM user whose access key is minted OUT OF BAND for the awslogs driver — never by Terraform (spec §5.9, G21)."
}

# ── cnayp-bot.kenesparta.dev legal pages (§5.11) ─────────────────────────────
# The three values the cnayp-discord-bot repo's publish workflow needs. None is
# a secret: the role is assumed over OIDC, so there is no key to leak and the
# ARN is useless to anyone whose GitHub token does not match the trust policy.

output "cnayp_bot_site_bucket" {
  value       = aws_s3_bucket.cnayp_bot_site.id
  description = "S3 sync target for the Terms of Service / Privacy Policy pages."
}

output "cnayp_bot_site_distribution_id" {
  value       = aws_cloudfront_distribution.cnayp_bot_site.id
  description = "For `aws cloudfront create-invalidation` after publishing a correction."
}

output "cnayp_bot_site_role_arn" {
  value       = aws_iam_role.github_actions_cnayp_bot_site.arn
  description = "Set as AWS_ROLE_ARN in the cnayp-discord-bot repo — assumed over OIDC, no key involved."
}

# No secret is ever an output — the CloudFront origin secret in particular
# (spec §8).
