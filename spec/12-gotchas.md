# 12. Known Constraints & Gotchas

**G1 — Lightsail region availability.** Lightsail exists in a subset of AWS regions and a subset of AZs within them.
Validate `availability_zone` before applying.

**G2 — ACM certificates cannot be installed on a Lightsail instance.** Standard ACM public certs are non-exportable;
Lightsail's own certificates attach only to load balancers, container services, and CDN distributions. The instance
always needs Let's Encrypt. (AWS added *exportable* ACM public certificates in 2025 — paid, with manual redeployment on
renewal. Verify pricing and renewal mechanics before considering it; Caddy + LE is free and zero-touch.)

**G3 — `aws_lightsail_instance_public_ports` is authoritative.** It replaces the entire firewall rule set, not merges
into it. Omitting port 22 removes SSH access. Every required port must be present in the resource.

**G4 — `user_data` forces instance replacement.** Editing `bootstrap.sh` destroys and recreates the instance on the next
apply. With Ansible owning host configuration, `bootstrap.sh` should never need to change after Phase 2, so the trap is
largely defused. It is still live — treat any plan showing instance replacement as data loss unless a snapshot exists.

**G4b — Ansible does not restore data.** A rebuilt host is configured, not repopulated. Postgres contents come from the
backup bucket, and that restore path is manual. Rehearse it before you need it.

**G5 — Lightsail instances cannot assume IAM roles.** Any AWS API access from the box (the backup bucket, for instance)
needs a long-lived access key on disk. This is the root cause of AD-10. If `aws_lightsail_bucket_access_key` is used,
the secret lands in state in plaintext — prefer creating it out of band.

**G6 — No custom AMIs.** Lightsail accepts only its own blueprints. Snapshots export to EC2 one-way and never import
back. Hardening must happen post-provision, not baked into an image.

**G7 — `.dev` is HSTS-preloaded.** Browsers refuse plaintext HTTP for this TLD entirely. A TLS misconfiguration makes
the site unreachable rather than degraded. Use Let's Encrypt's staging endpoint while iterating on origin certificates.

**G8 — Let's Encrypt rate limits.** 50 certificates per registered domain per week, counted across *all* subdomains —
the `origin-*` names share the `kenesparta.dev` budget with everything else. Caddy's `/data` volume must persist across
container recreation or repeated re-issuance can trigger a multi-day lockout.

**G9 — Static IP billing.** Free while attached to a running instance; charged (~$3.60/mo) if left allocated but
unattached. A partial `destroy` can leave one orphaned.

**G10 — Never `terraform destroy` in `kenesparta.dev/tf`.** That state owns the Route 53 zones, their DNSSEC
key-signing keys, and the KMS keys. Destroying it would break mail delivery to the Proton addresses, not merely the
website, and KMS keys enter a 7-day deletion window that cannot be shortened. Retirement means *deleting the directory*
after Phase 0 verifies the new state, never running destroy in it.

**G11 — CloudFront origins cannot be firewalled off on Lightsail.** Instance firewalls take plain CIDR lists and cannot
reference the `com.amazonaws.global.cloudfront.origin-facing` managed prefix list; those ranges rotate. The shared
`X-Origin-Verify` header is the only lockdown available, and it is an application-layer control, not a network one.

**G12 — CloudFront origins must be hostnames, not IP addresses.** This is why `origin-<project>` records exist at all.

**G13 — The origin secret is a two-sided rotation.** It lives in Terraform state (as a `custom_header`) and in Ansible
Vault (as the Caddy comparison value). Change Terraform first, then Ansible; the reverse order 403s every request in
between.
