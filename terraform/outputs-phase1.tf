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

# ── auruming.com registrar handoff (§5.12, G23, rev 2.12) ────────────────────
# The two values a human has to retype into the Namecheap dashboard, and the
# only part of this estate Terraform cannot do itself. `make dns/auruming`
# prints them together, labelled, in the order G23 needs them.
#
# Neither is a secret (spec §8): nameservers and a DS record are published in
# the public DNS by design — a DS is a hash of a public key whose entire purpose
# is being readable by every resolver on the internet.

output "auruming_nameservers" {
  value       = aws_route53_zone.auruming.name_servers
  description = "G23 step 3 — paste into Namecheap > Domain > Nameservers > Custom DNS, BEFORE `make apply` can validate the certificate."
}

output "auruming_ds_record" {
  # The provider exposes the assembled DS rdata, so there is no digest to
  # compute by hand — key tag, algorithm, digest type and digest, in the order a
  # registrar's form expects them.
  value       = aws_route53_key_signing_key.auruming.ds_record
  description = "G23 step 6 — paste into Namecheap > Advanced DNS > DNSSEC. LAST, and only after the delegation is live and signing reports ACTIVE: a DS published over an unsigned or undelegated zone is SERVFAIL for every validating resolver."
}

# ── cdn.auruming.com asset CDN (§5.13) ───────────────────────────────────────

output "auruming_cdn_bucket" {
  value       = aws_s3_bucket.auruming_cdn.id
  description = "S3 upload target for auruming.com's images/video. No CI role writes it yet (§5.13) — publish with `aws s3 cp/sync` under the SSO profile."
}

output "auruming_cdn_distribution_id" {
  value       = aws_cloudfront_distribution.auruming_cdn.id
  description = "For `aws cloudfront create-invalidation` after replacing an asset in place."
}

output "auruming_cdn_domain" {
  value       = local.auruming_cdn_domain
  description = "Public hostname assets are served from."
}
