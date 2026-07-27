# 4. Scope Boundary

## Terraform-managed

**Migrated in from `kenesparta.dev/tf` (addresses preserved):**

- Route 53 zones `kenesparta.dev` and `kecc.link`, both DNSSEC-signed, with their KMS key-signing keys
- Proton mail records (MX, SPF, 3× DKIM, DMARC) and the Discord verification record
- ACM certificate (`kenesparta.dev` + `*.kenesparta.dev`) and its DNS validation records
- `cdn.kenesparta.dev` — S3 bucket, CloudFront distribution, OAC, CORS response-headers policy
- GitHub Actions OIDC provider and deploy role

**New:**

- SSH key pair (from `~/.ssh/personal-infra.pub`)
- Lightsail instance (bundle, blueprint, availability zone), static IP and attachment
- Instance firewall rules, automatic snapshot add-on
- `origin-<project>.kenesparta.dev` A records
- Per-project CloudFront distributions with the origin secret header
- Lightsail bucket for database backups, and the instance→bucket resource access that replaces its access key (G5)
- One-time bootstrap via `user_data`

**Destroyed:**

- Lightsail Container Service and its deployment version
- ECR repository, lifecycle policy, and repository policy
- The CI role's `ecr-push-policy`, `lightsail-deploy-policy`, and `tf-state-policy`
- The Lightsail managed PostgreSQL database (manually, after the restore is verified)

## Ansible-managed (host configuration)

- Base packages, `unattended-upgrades`, timezone, `fail2ban`
- Docker Engine, Compose plugin, the external `web` network
- GHCR registry authentication
- PostgreSQL: a single container on `web` publishing no host port, per-project databases and roles (AD-3)
- Caddy stack and templated `Caddyfile`, including the origin-secret gate
- systemd deploy units and timers
- `pg_dump` backup script and its timer
- CIS hardening via `usg` (separate playbook — see A4)

## Out of scope (neither tool)

| Concern                     | Owned by                           |
|-----------------------------|------------------------------------|
| Application images          | GitHub Actions → GHCR              |
| Container lifecycle         | systemd timer on the host          |
| Origin TLS certificates     | Caddy (ACME HTTP-01, automatic)    |
| Database schemas/migrations | Application-level (`sqlx migrate`) |

**The seam:** Terraform produces a reachable host, its static IP, and everything at the AWS edge. Ansible consumes that
IP and produces a host ready to run containers. Neither tool crosses into the other's territory, and neither deploys
application code.
