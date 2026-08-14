# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Git

- **Commit only as the current user.** Never append a `Co-Authored-By: Claude ...` trailer or a "Generated with Claude
  Code" footer to a commit message — the message ends with its last content line. The same applies to PR bodies.
- `main` is committed to directly; the history is linear and there is no PR workflow. Subjects follow `feat: ...`.

## Current state

**The migration is complete — all phases 0–9 (2026-07-27).** The instance serves two web projects in production:
`kenesparta.dev` (blog) and `api.kenesparta.dev` (budget API — backend of the iOS app; formerly the budget Telegram
bot at `bot.kenesparta.dev`, rev ≤2.5), each behind its own CloudFront distribution →
Caddy (Let's Encrypt) → container, with data restored into the host Postgres. A third project, `cnayp_discord_bot`, is
**headless** (rev 2.10): a Discord gateway bot holding an outbound WSS connection, with no hostname, no origin, no
Caddy vhost and no certificate — see `projects.yml` below. Its Terms of Service and Privacy Policy are a separate
static site at `cnayp-bot.kenesparta.dev` (S3 + CloudFront, rev 2.11), deliberately not served by the bot. The old
estates are gone: the container
services, ECR repositories, managed database, `../kenesparta.dev/tf` and `../budget-assistant/deploy/tf` are all
destroyed or deleted; this repository's state (`s3://tf.kenesparta.dev/infra/prod/terraform.tfstate`) is the account's
only live Terraform. The host is Ubuntu-Pro-attached and CIS Level 1 hardened — via the **G18-tailored profile only**,
never bare `usg fix cis_level1_server`. The backup path is proven end-to-end: dumps upload nightly to
`s3://kenesparta-infra-backups/postgres/<db>/` and a bucket→scratch-database restore was rehearsed 2026-07-27 with
row-for-row parity. The final pre-migration dumps live at `s3://kenesparta-infra-backups/managed-db-final/`; the
pre-hardening rollback snapshot is `pre-harden-2026-07-27`.

Read `spec/` before touching anything — it is rev 2.11 and records decisions that reverse parts of earlier revisions;
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

`hostname`, `origin` and `port` are the **ingress set**: optional, but only *as a set* (spec §5.3 rev 2.10). Omitting
all three makes a project **headless** — no distribution, no alias records, no origin A record, no vhost, no
certificate — which is what `cnayp_discord_bot` is. `name`, `image` and `database` stay mandatory. `site.yml` asserts
all-three-or-none rather than defaulting the gap: an entry that lost its `origin` to a typo would silently stop getting
a vhost and a cert, and on an HSTS-preloaded domain (G7) that is an outage found by a user. Absence is the marker;
there is deliberately no `public:` flag. In Terraform the two subsets are `local.origin_projects` (has an `origin`;
includes blog) and `local.edge_projects` (has a `hostname`; excludes blog) — never read `each.value.hostname` off
`local.projects`, which is heterogeneous by design.

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
- **Host snapshots are weekly manual snapshots that never expire on their own** (G20). The AutoSnapshot add-on is
  disabled — it is daily-only, with fixed seven-copy retention — and an EventBridge rule fires the
  `kenesparta-host-weekly-snapshot` Lambda Sundays 06:00 UTC, which creates `kenesparta-host-weekly-<date>` and prunes
  to the newest four *by name prefix*. Renaming the prefix orphans every existing weekly snapshot (billed until
  hand-deleted); names outside it (`pre-harden-*`) are never touched; and a broken Lambda stops snapshot *creation*
  silently — there is no alarm at this scale.
- **The CDN's `immutable` header cannot be taken back** (G19). On `cdn.kenesparta.dev`, `fonts/*` and `blog/*` carry
  `Cache-Control: public, max-age=31536000, immutable` — a browser that holds an object keeps it for a year and no
  CloudFront invalidation can reach it, so changing an asset there means renaming it. Stable-name objects overwritten
  in place (`cv/ken_esparta_cv.pdf`, `img/*`) stay on the default behavior, whose five-minute fallback has override
  **off** so the typst-resume CI's own `max-age=3600` on the CV wins. The headers land on error responses too — an
  asset must exist before anything references it, or the 403 gets pinned as well.
- **The legal pages are G19 in reverse** (spec §5.11). `cnayp-bot.kenesparta.dev` serves the Terms of Service and
  Privacy Policy Discord requires, and they are stable names overwritten in place — the whole point of updating one is
  that readers see the new text. No immutable behavior may ever exist on that distribution; it caches five minutes with
  `min_ttl = 0`, and CI holds `CreateInvalidation` on it. Its S3 origin is behind OAC without `s3:ListBucket`, so a
  missing key returns **403, not 404**; both map to `/404.html`, which makes that file mandatory in the upload set.
  Publishing uses `github-actions-cnayp-bot-site` — its *own* role on purpose, because the older
  `github-actions-ecr-ecs-deploy` carries CDN write and adding a repo to its trust policy would grant it silently.
- **A new project needs three things applied before `make configure`, in order** (G22): `terraform apply` for the log
  group (G21), the vault entries, and then a `docker push` so the image exists. The deploy role's "Start each project"
  does a real pull, so a missing image fails the play *after* the host has been changed — unlike the first two, which
  fail early. If the image is not ready, leave the project out of `projects.yml` rather than commit an entry that
  cannot converge.
- **IAM tag *values* reject apostrophes.** They are validated against `[\p{L}\p{Z}\p{N}_.:/=+\-@]*` — letters, digits,
  separators and that punctuation only. A `Description` tag reading "the app's pages" fails `CreateRole` with a
  `ValidationError` naming an opaque `tags.N.member.value`. S3 and CloudFront tags are more permissive; IAM is the one
  that bites, and it does so mid-apply.
- **Idempotency is an acceptance criterion.** A second consecutive `make configure` must report zero `changed`. Use
  handlers; never restart unconditionally.
- **Hardening is a separate playbook.** `usg fix` can lock you out. Snapshot, run `harden.yml`, verify
  SSH from a *second* terminal before closing the first, then re-run `site.yml`. Guard `usg fix` with `creates:`.
  It runs **only** with the G18 tailoring file: the stock profile's host-firewall chapter flushes Docker's chains and
  the metadata guard, re-enables `nftables.service`, and zeroes `ip_forward` — applied bare in Phase 8, it took
  container networking down until repaired.
- **Secrets:** Postgres passwords, the GHCR PAT, the CloudWatch logs key and the origin secret live in `ansible/group_vars/vault.yml`
  (ansible-vault); `vault.yml.example` is the committed, key-names-only template. This repo *also* uses **sops + age**
  for `secrets/prod.enc.env`, read by Terraform — two different mechanisms, do not conflate them.
- **Exactly one static AWS credential exists on the host** (AD-11, G21): the CloudWatch logs-writer key, scoped to
  `logs:CreateLogStream`/`PutLogEvents` on `/kenesparta/*`, held in Ansible Vault and deployed as a root-only dockerd
  drop-in. It is minted out of band — never `aws_iam_access_key`, whose secret half would sit in state (G5). Everything
  else still holds: the backup path uses bucket resource access via instance metadata, which does **not** generalise to
  other services, so AD-10 (GHCR over ECR) stands. The writer deliberately cannot create log groups — they are
  Terraform's, with 7-day retention — so a container whose group is missing **fails to start**: apply Terraform before
  `make configure`, and never delete a `/kenesparta/*` group while a container references it.
- **Never remove `imds-guard.service`** while resource access is in place (G16). Metadata is reachable from any
  container on a Docker bridge, so that one nftables DROP is the only thing stopping an application container from
  reading every project's database dumps out of the backup bucket. It is a **native nftables table of its own**
  (`personal_infra_guard`), deliberately not a rule in Docker's `DOCKER-USER` chain: Docker rebuilds its chains on every
  daemon start and cannot touch a separate table, and an independent table can be ordered *before* `docker.service`.
  Consequences: `iptables -S` will not show it (use `nft list table inet personal_infra_guard`), and Ubuntu's
  `nftables.service` must stay disabled because its stock config begins with `flush ruleset` — the docker role enforces
  this since Phase 8 (G18).
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
