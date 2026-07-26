# 3. Architecture Decisions

Each decision records what was chosen, why, and what was explicitly rejected. Do not re-litigate during implementation.

## AD-1 — Lightsail instance over EC2 and over Lightsail Containers

**Chosen:** Lightsail **Small** bundle `small_3_0` — 2 vCPU, 2 GB RAM, 60 GB SSD, 3 TB transfer, dual-stack, $12/mo —
Ubuntu 24.04.

**Rationale:** EC2 at equivalent spec costs more once storage, IPv4, and egress are unbundled. The current Container
Service (`nano`, 0.25 vCPU / 512 MB) is cheaper still but hosts exactly one container, cannot run Postgres, and gives
no shell. At $12 the whole estate lands *below* today's bill ([§14](14-cost.md)) while gaining a shell and room for more than one
service.

**RAM is the binding constraint, not CPU or disk.** Indicative budget at 2 GB:

| Component                          | Resident |
|------------------------------------|----------|
| OS + Docker daemon                 | ~350 MB  |
| PostgreSQL (tuned, see below)      | ~400 MB  |
| Caddy                              | ~50 MB   |
| Each Rust service (Leptos SSR)     | ~100 MB  |

At C3's ceiling of **four services** that totals ~1.2 GB, leaving ~800 MB for page cache and burst — a real margin
rather than a squeeze. This is why C3 is four and not more: four fits `small_3_0` with headroom, and each additional
service costs ~100 MB against a fixed 2 GB. The `projects.yml` fan-out means growing past four is a bundle change, not
a redesign.

The ~100 MB per-service figure assumes a release-mode Leptos SSR binary. A service that holds large caches or does
image processing will not fit that budget — measure before adding the fourth.

Postgres must be tuned down from Ubuntu's defaults for this to hold: `shared_buffers = 256MB`,
`effective_cache_size = 768MB`, `max_connections = 40`, `work_mem` small. The `postgres` role owns these; leaving
defaults on a 2 GB box invites the OOM killer.

**Trigger to resize:** sustained memory pressure (swap in use, or a container OOM-killed). `medium_3_0` ($24, 4 GB) is a
stop/change-bundle/start operation on a snapshot — minutes of downtime, no redesign, no data movement if the snapshot
is current.

**Rejected:** EC2 (revisit only if custom AMI pipelines become necessary); staying on Lightsail Containers (does not
meet C3); `medium_3_0` up front (pays $12/mo for capacity that is not yet needed — the trigger above buys it when it
is).

## AD-2 — No load balancer

**Chosen:** Caddy on the instance, ports 80/443 published directly.

**Rationale:** An ALB costs ~$16–22/mo before traffic and provides no availability benefit in front of a single
instance.

**Rejected:** ALB, NLB, and a dedicated reverse-proxy VM. The latter adds cost, a network hop, and a second point of
failure without removing the first.

*Amended in rev 2:* this decision rejects a **load balancer**, not the CDN. CloudFront is retained — see AD-8.

## AD-3 — Self-hosted PostgreSQL, one instance, one database per project

**Chosen:** One Postgres process on the host, one `DATABASE` and one role per project, bound to `127.0.0.1`.

**Rationale:** Four Postgres containers would each carry independent `shared_buffers`, WAL, and autovacuum overhead —
roughly 4× the fixed cost for the same data, which a 2 GB host cannot absorb (AD-1). One instance means one backup job
and one upgrade path. Replaces the current Lightsail managed database, saving ~$15/mo.

**Rejected:** Lightsail managed database (the value is automated backups, replaceable by a `pg_dump` cron for ~$1);
Supabase and equivalent BaaS, per user constraint.

**Migration note:** the production write path is the `ingest` CLI only — the web app never writes. Postgres is therefore
effectively read-only in production, so the dump/restore carries no concurrent-write hazard.

## AD-4 — Caddy over Traefik/nginx

**Chosen:** Caddy 2, templated Caddyfile, **stock image — no plugins**.

**Rationale:** Automatic ACME issuance and renewal with no plugin. Static config is easier to debug under failure.

**Consequence for rev 2:** "no plugins" rules out the Route 53 DNS-01 provider, which forces the origin-hostname design
in AD-8. Every hostname Caddy holds a certificate for must resolve **directly to the instance** so HTTP-01 can succeed.

## AD-5 — Pull-based deployment

**Chosen:** CI pushes images to GHCR; the instance polls via a systemd timer running
`docker compose pull && docker compose up -d`.

**Rationale:** Requires zero inbound connectivity for deploys. Push-based SSH from GitHub-hosted runners would require
opening port 22 to GitHub's broad, rotating IP ranges.

**Consequence for rev 2:** CI no longer performs a `terraform apply`. The GitHub OIDC role sheds its ECR-push,
Lightsail-deploy, and Terraform-state policies, retaining only the `cdn.kenesparta.dev` S3 write used by the
`typst-resume` repository.

**Rejected:** SSH-based deploy actions, self-hosted runners.

## AD-6 — Terraform manages infrastructure only

**Chosen:** Terraform provisions the instance, IP, firewall, DNS, certificates, CDN, and backup bucket. It does **not**
manage application deployment, Caddyfile contents, database schemas, or container lifecycle.

**Rationale:** Those change on a different cadence and belong to the deploy pipeline. Mixing them causes Terraform to
fight the running system.

## AD-7 — Ansible for configuration management

**Chosen:** Ansible owns everything between "instance exists" and "applications can be deployed."

**Rationale:** Gotcha G4 is the forcing function. `user_data` is `ForceNew` on `aws_lightsail_instance`, so every config
change routed through Terraform destroys and recreates the host. That leaves three options: keep config in a long
`user_data` script and accept replacement on every edit; do it manually and lose reproducibility; or hand mutable host
state to a config-management tool. Only the third is viable.

Ansible specifically because it is **agentless** — it runs over the SSH connection that already exists, consistent with
the decision to keep no daemons on the box (AD-5). It also gives the spec a secrets story: Postgres passwords, the GHCR
token, and the CloudFront origin secret live in Ansible Vault rather than in Terraform state.

**Consequence:** `bootstrap.sh` shrinks to the minimum needed to accept an Ansible connection. Everything else moves
into roles. G4's blast radius drops from "any config change" to "almost never."

**Rejected:** cloud-init alone (same ForceNew problem); shell scripts over SSH (no idempotency, no dry-run);
Chef/Puppet/Salt (require an agent or a server).

## AD-8 — CloudFront is retained; one distribution and one origin hostname per project

**Chosen:** Each project gets its own CloudFront distribution and its own `origin-<project>.kenesparta.dev` A record
pointing at the static IP. Public hostname → CloudFront (ACM cert) → origin hostname → Caddy (Let's Encrypt cert) →
container.

**Rationale:** three facts collide and only this shape satisfies all of them.

1. **ACM certificates cannot be installed on a Lightsail instance.** Standard ACM public certs are non-exportable, so
   the box can never serve the ACM cert directly. Lightsail's own certificate service has the same restriction — it
   attaches to load balancers, container services, and CDN distributions, never to an instance. The host therefore needs
   Let's Encrypt regardless of what sits in front of it.
2. **CloudFront routes by path pattern, not by Host.** One distribution with four aliases sends all four to the same
   origin under the same behavior, so a single distribution cannot fan out to four backends.
3. **A hostname that resolves to CloudFront cannot satisfy an HTTP-01 challenge on the instance** — the challenge
   request lands at the CDN. Caddy can therefore only obtain certificates for names that point straight at the box, and
   AD-4 forbids the DNS-01 plugin that would lift that restriction.

Per-project distributions cost nothing extra: CloudFront bills for requests and transfer, not per distribution.

**Origin lockdown:** Lightsail instance firewalls accept plain CIDR lists and **cannot** reference the
`com.amazonaws.global.cloudfront.origin-facing` managed prefix list, and CloudFront's origin ranges rotate. The origin
is therefore protected by a shared secret instead: each distribution injects `X-Origin-Verify: <secret>` via
`custom_header`, and Caddy returns 403 to any request lacking it. The secret lives in Ansible Vault and in Terraform
state; rotating it is a two-sided change.

**Rejected:**
- *Single distribution forwarding the viewer Host* — requires Caddy to hold certs for names pointing at CloudFront,
  i.e. DNS-01, i.e. a custom Caddy build (violates AD-4).
- *Single distribution, HTTP-only origin* — removes the cert problem but sends all origin traffic in plaintext across
  the public internet, protected only by the shared secret.
- *Lightsail CDN distribution* — takes the instance as origin directly and is cheaper, but is far less configurable and
  would retire the existing ACM cert for the apex.
- *No CDN at all* (rev 1's C4) — simplest and free, but discards the working CloudFront estate and publishes the origin
  IP.

## AD-9 — State consolidation by copying the state object, not by import blocks

**Chosen:** copy `s3://tf.kenesparta.dev/dns/prod/kenesparta.dev` to the new key, then evolve the configuration in
place: keep the `.tf` files for resources that survive (under identical resource addresses), add the new instance
resources, and remove the container-service and ECR resources.

**Rationale:** the old state already contains every resource that is moving. Copying it preserves ~25 resources with
zero import statements and zero risk of an address typo silently orphaning a resource. Resource addresses are preserved
verbatim (`aws_route53_zone.kenespartadev`, `aws_kms_key.kenespartadev_key_dnssec`, …), so Terraform sees no diff for
anything that is not deliberately changing.

The old state object is left in place untouched as a rollback point.

**Rejected:** `import {}` blocks for every resource (~25 hand-written IDs, several of which — DNSSEC key-signing keys,
CloudFront OAC, ACM validation records — have non-obvious ID formats); `terraform state mv` across backends (no
cross-backend support).

**Absolutely forbidden:** running `terraform destroy` in `kenesparta.dev/tf`. See G10.

## AD-10 — GHCR over ECR

**Chosen:** images published to `ghcr.io/kenesparta/<project>`; the instance authenticates with a GHCR PAT held in
Ansible Vault.

**Rationale:** a Lightsail instance **cannot assume an IAM role** (G5). Pulling from ECR from the box would require a
long-lived IAM access key on disk *plus* a second systemd timer re-running `aws ecr get-login-password` before the
12-hour token expires. A GHCR PAT is one credential with no refresh machinery. CI authenticates to GHCR with the
built-in `GITHUB_TOKEN`, removing AWS from the build job entirely.

**Consequence:** the ECR repository, its lifecycle policy, its Lightsail pull policy, and the CI role's ECR policy are
all destroyed.
