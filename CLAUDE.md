# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Current state

**The migration is complete through Phase 7 (2026-07-27).** The instance serves both projects in production:
`kenesparta.dev` (blog) and `bot.kenesparta.dev` (budget Telegram bot), each behind its own CloudFront distribution →
Caddy (Let's Encrypt) → container, with data restored into the host Postgres. The old estates are gone: the container
services, ECR repositories, managed database, `../kenesparta.dev/tf` and `../budget-assistant/deploy/tf` are all
destroyed or deleted; this repository's state (`s3://tf.kenesparta.dev/infra/prod/terraform.tfstate`) is the account's
only live Terraform. **Remaining: Phase 8 (hardening — needs an Ubuntu Pro token in the vault and a snapshot first) and
Phase 9 (backup-restore rehearsal).** The final pre-migration dumps live at
`s3://kenesparta-infra-backups/managed-db-final/`.

Read `spec/` before touching anything — it is rev 2.3 and records decisions that reverse parts of earlier revisions;
`spec/10-phases.md` carries as-executed annotations where reality diverged from the plan.

## `spec/` is the source of truth

The spec is one file per numbered section, indexed by `spec/README.md`; section numbers are stable and are what code
comments cite (`spec §5.3`). It is written to be authoritative:

- Do not introduce resources or patterns not described in it. If a gap is found, **amend the spec first**, then
  implement.
- `spec/03-decisions.md` (AD-1..AD-10) records what was chosen *and what was rejected*, with the rejected alternatives
  spelled out. Do not re-litigate.
- `spec/02-constraints.md` lists constraints as fixed inputs, not preferences to optimize away.
- `spec/10-phases.md` defines the migration phase order; `spec/11-acceptance.md` the acceptance criteria.

## What is being migrated, and from where

`../kenesparta.dev` today runs a Leptos/Rust site on a **Lightsail Container Service** (`nano`) fronted by CloudFront,
pulling a private ECR image, backed by a **Lightsail managed PostgreSQL** created outside Terraform. Its Terraform lives
in `../kenesparta.dev/tf` with state at `s3://tf.kenesparta.dev/dns/prod/kenesparta.dev`.

The target is a Lightsail **instance** (Ubuntu 24.04, `small_3_0` — 2 GB / 2 vCPU / 60 GB, $12/mo) running Docker
Compose + Caddy + self-hosted Postgres, configured by Ansible, with images pulled from GHCR by a systemd timer.

The managed source database is **PostgreSQL 18.4**, so the self-hosted one is pinned to `postgres:18` — `pg_restore`
only moves forward across majors (G14). It runs as a **container on the `web` network**, not as an apt package: an
application container's `127.0.0.1` is its own namespace, so a host Postgres bound to loopback would be unreachable
from the very things that need it. Applications reach it as `postgres:5432`, and nothing listens on 5432 on the host
(AD-3, amended in rev 2.1).

**RAM is the binding constraint at this bundle** (AD-1), which is why C3 caps at **four services**: ~350 MB OS+Docker,
~400 MB tuned Postgres, ~50 MB Caddy, ~100 MB per service — about 1.2 GB of 2 GB at the ceiling. Postgres must be tuned
down from Ubuntu's defaults (`shared_buffers = 256MB`, `max_connections = 40`) or the OOM killer will find it. Growing
past four is a bundle change to `medium_3_0` on a snapshot, not a redesign.

**After the migration `../kenesparta.dev/tf` is deleted** and this repository holds the account's only Terraform state.

## Architecture: three seams

**1. Terraform / Ansible.** Terraform provisions the instance, IP, firewall, snapshots, and everything at the AWS edge
(Route 53, ACM, CloudFront, S3, IAM). Ansible owns everything between "instance exists" and "applications can be
deployed". Neither deploys application code — CI pushes to GHCR and a systemd timer on the host runs
`docker compose pull && up -d` (AD-5, A5).

**2. The edge.** Public hostname → CloudFront (ACM cert) → `origin-<project>.kenesparta.dev` → Caddy (Let's Encrypt
cert) → container. **One distribution and one origin hostname per project.** This shape is forced by three facts that
appear in different files, so it looks over-complicated until you know all three (AD-8):

- ACM certs cannot be installed on a Lightsail instance — they are non-exportable, so the box always needs Let's
  Encrypt regardless of what fronts it.
- CloudFront routes by path pattern, **not by Host**, so one distribution cannot fan several hostnames out to several
  backends.
- A hostname pointing at CloudFront cannot satisfy an HTTP-01 challenge on the instance, and AD-4 forbids the Caddy
  DNS-01 plugin that would work around it. Every name Caddy holds a cert for must resolve *directly* to the box.

Per-project distributions cost nothing extra — CloudFront bills per request and per GB, not per distribution.

**3. `projects.yml`.** One file at the repository root, read by *both* tools — Terraform via `yamldecode`, Ansible via
`vars_files`. It drives origin DNS records, CloudFront distributions, Caddy vhosts, Postgres databases, and deploy
timers together. Adding a project is a five-line change in one file. Never let the two tools carry separate copies.

The Terraform→Ansible handoff is a generated `ansible/inventory/hosts.ini` written by `make inventory` from
`terraform output -raw static_ip`. Deliberately *not* a Terraform `local_file` resource — that would couple
`terraform destroy` to Ansible's working tree.

## Commands

Terraform work happens in `terraform/`, Ansible in `ansible/`; a root `Makefile` ties the stages together. `make help`
lists everything, grouped.

```bash
make deps          # install community.docker (the only collection dependency)
make vault/create  # ansible/group_vars/vault.yml from the committed template
make inventory     # regenerate ansible/inventory/hosts.ini from terraform output
make configure     # ansible-playbook site.yml   (all host config except hardening)
make harden        # ansible-playbook harden.yml (deliberate, never part of site.yml)
make syntax        # parse both playbooks without touching the host
```

AWS access is SSO and expires. Before any apply:

```bash
make login      # aws sso login --profile $TF_VAR_aws_sso_profile (from terraform/.env)
```

Verify blueprint/bundle IDs before applying — they change over time:

```bash
aws lightsail get-blueprints --query 'blueprints[?platform==`LINUX_UNIX`].[blueprintId,name]' --output table
aws lightsail get-bundles    --query 'bundles[].[bundleId,ramSizeInGb,price]' --output table
```

## Rules that bite

Failure modes that are not obvious from any single file (`spec/12-gotchas.md`):

- **Never delete `s3://tf.kenesparta.dev/dns/prod/kenesparta.dev`.** The old `tf/` directory is gone (Phase 7), but
  that frozen state object is the migration's rollback point (G10) and stays. This repo's state now owns the Route 53
  zones, their DNSSEC key-signing keys, and the KMS keys — a `terraform destroy` *here* breaks mail delivery to the
  Proton addresses, not just the websites, and KMS keys enter an unshortenable 7-day deletion window.
- **State moved by copying the S3 object, not by `import` blocks** (AD-9), preserving resource addresses verbatim.
  The Phase 0 zero-diff gate passed 2026-07-27 and is historical — since the Phase 6 origin swap it can no longer be
  green, and `make plan/phase0` says so before running.
- **`user_data` is `ForceNew`.** Editing `terraform/bootstrap.sh` destroys and recreates the instance. Keep it to the
  minimum that lets Ansible connect. Treat any plan showing instance replacement as data loss unless a snapshot exists.
- **`aws_lightsail_instance_public_ports` is authoritative, not additive.** It replaces the whole rule set — omitting
  port 22 removes SSH. Port 80 must stay open for HTTP-01 on the origin hostnames.
- **The origin cannot be firewalled to CloudFront.** Lightsail firewalls take plain CIDRs and cannot reference the
  `com.amazonaws.global.cloudfront.origin-facing` prefix list. The `X-Origin-Verify` shared header is the only lockdown
  available, and it is application-layer, not network-layer.
- **The origin secret is a two-sided rotation.** It lives in Terraform state (`custom_header`) and Ansible Vault (the
  Caddy comparison). Change Terraform first, then Ansible — the reverse order 403s every request in the gap.
- **Let's Encrypt limits are per registered domain.** The `origin-*` names share `kenesparta.dev`'s 50-cert weekly
  budget with everything else. Caddy's `/data` volume must persist across container recreation, and `.dev` is
  HSTS-preloaded so a TLS error makes the site unreachable rather than degraded — iterate against LE staging.
- **Idempotency is an acceptance criterion.** A second consecutive `make configure` must report zero `changed`. Use
  handlers; never restart unconditionally.
- **Hardening is a separate playbook.** `usg fix cis_level1_server` can lock you out. Snapshot, run `harden.yml`, verify
  SSH from a *second* terminal before closing the first, then re-run `site.yml`. Guard `usg fix` with `creates:`.
- **Secrets:** Postgres passwords, the GHCR PAT and the origin secret live in `ansible/group_vars/vault.yml`
  (ansible-vault); `vault.yml.example` is the committed, key-names-only template. This repo *also* uses **sops + age**
  for `secrets/prod.enc.env`, read by Terraform — two different mechanisms, do not conflate them.
- **There is no AWS credential on the host.** G5's old claim that *any* AWS access needs a key on disk was wrong for
  Lightsail buckets: `aws_lightsail_bucket_resource_access` attaches the instance to the backup bucket and the AWS CLI
  takes short-lived credentials from instance metadata. It does **not** generalise to other services, so AD-10 (GHCR
  over ECR) still stands — there is no such attachment for ECR.
- **Never remove `imds-guard.service`** while resource access is in place (G16). Metadata is reachable from any
  container on a Docker bridge, so that one nftables DROP is the only thing stopping an application container from
  reading every project's database dumps out of the backup bucket. It is a **native nftables table of its own**
  (`personal_infra_guard`), deliberately not a rule in Docker's `DOCKER-USER` chain: Docker rebuilds its chains on every
  daemon start and cannot touch a separate table, and an independent table can be ordered *before* `docker.service`.
  Consequences: `iptables -S` will not show it (use `nft list table inet personal_infra_guard`), and Ubuntu's
  `nftables.service` must stay disabled because its stock config begins with `flush ruleset`.
- **The Phase 0 gate is historical** (passed 2026-07-27). It moved the additive `.tf` files aside so it answered only
  "did the state copy land correctly?"; since the Phase 6 origin swap and Phase 7 deletion of `legacy.tf` it can no
  longer report clean, and the target now prints a notice saying so.
- **The backup bucket's access key is created out of band, on purpose.** `aws_lightsail_bucket_access_key` would write
  the secret half into Terraform state in plaintext (G5). Same reasoning as AD-10's GHCR PAT.

## Conventions

- **No shell scripts where an Ansible module exists** (A6). `bootstrap.sh` is the only permitted script, and only
  because `user_data` requires one. `command`/`shell` need `creates:`, `removes:`, or `changed_when:`.
- Flat structure within each stage — no Terraform modules, no Ansible roles beyond the seven in `spec/09-ansible.md`,
  until a second environment exists.
- `terraform/terraform.tfvars` and `ansible/inventory/hosts.ini` are gitignored; `terraform.tfvars.example` and
  `group_vars/vault.yml.example` are committed and must contain no real values. `group_vars/vault.yml` **is** committed,
  but only ever ansible-vault encrypted — `make vault/check` verifies that before you push.
- Terraform ≥ 1.10 (S3 backend `use_lockfile`, no DynamoDB table); the application repo pins 1.15.8 in CI, so match it.
- Docker comes from Docker's apt repo, not the distro `docker.io` package. Postgres binds `127.0.0.1` only, and no
  container publishes host ports except Caddy.
- The spec names the project `kenesparta-infra`; this directory is `personal-infra`. The directory name wins.
