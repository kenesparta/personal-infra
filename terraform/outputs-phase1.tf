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

# No secret is ever an output — the CloudFront origin secret in particular
# (spec §8).
