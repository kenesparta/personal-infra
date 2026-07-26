# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Current state

The repository is **pre-Phase 1**: `spec/`, `terraform/`, `projects.yml`, and the `Makefile` exist, `ansible/` does not
yet, and `main` has no commits. Everything below describes what is to be built.

This is not a greenfield project. It is a **migration** that absorbs a working estate from a second repository,
`../kenesparta.dev` (added to the session with `/add-dir`). Read `spec/` before touching anything — it is rev 2 and
records decisions that reverse parts of rev 1.

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

Terraform work happens in `terraform/`, Ansible in `ansible/`; a root `Makefile` ties the stages together:

```bash
make inventory     # regenerate ansible/inventory/hosts.ini from terraform output
make configure     # ansible-playbook site.yml   (all host config except hardening)
make harden        # ansible-playbook harden.yml (deliberate, never part of site.yml)
```

AWS access is SSO and expires. Before any apply, log in from the *application* repo, which holds the profile name:

```bash
cd ../kenesparta.dev/tf && make login      # aws sso login --profile $TF_VAR_aws_sso_profile
```

Verify blueprint/bundle IDs before applying — they change over time:

```bash
aws lightsail get-blueprints --query 'blueprints[?platform==`LINUX_UNIX`].[blueprintId,name]' --output table
aws lightsail get-bundles    --query 'bundles[].[bundleId,ramSizeInGb,price]' --output table
```

## Rules that bite

Failure modes that are not obvious from any single file (`spec/12-gotchas.md`):

- **Never run `terraform destroy` in `../kenesparta.dev/tf`.** That state owns the Route 53 zones, their DNSSEC
  key-signing keys, and the KMS keys. Destroying it breaks mail delivery to the Proton addresses, not just the website,
  and KMS keys enter an unshortenable 7-day deletion window. Retirement means *deleting the directory* after Phase 0
  verifies the new state.
- **State moves by copying the S3 object, not by `import` blocks** (AD-9). Resource addresses must be preserved
  verbatim — `aws_route53_zone.kenespartadev`, `aws_kms_key.kenespartadev_key_dnssec`, and so on. Phase 0's gate is
  `terraform plan` reporting **no changes**; do not proceed past it on a dirty plan.
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
- **Secrets:** Postgres passwords, the GHCR PAT, and the origin secret live in `ansible/group_vars/vault.yml`
  (ansible-vault). The application repo separately uses **sops + age** for `secrets/prod.enc.env` — two different
  mechanisms, do not conflate them.

## Conventions

- **No shell scripts where an Ansible module exists** (A6). `bootstrap.sh` is the only permitted script, and only
  because `user_data` requires one. `command`/`shell` need `creates:`, `removes:`, or `changed_when:`.
- Flat structure within each stage — no Terraform modules, no Ansible roles beyond the seven in `spec/09-ansible.md`,
  until a second environment exists.
- `terraform/terraform.tfvars` and `ansible/inventory/hosts.ini` must be gitignored — `.gitignore` currently contains
  only `.idea`, so both entries still need adding. `terraform.tfvars.example` is committed and must contain no real
  values.
- Terraform ≥ 1.10 (S3 backend `use_lockfile`, no DynamoDB table); the application repo pins 1.15.8 in CI, so match it.
- Docker comes from Docker's apt repo, not the distro `docker.io` package. Postgres binds `127.0.0.1` only, and no
  container publishes host ports except Caddy.
- The spec names the project `kenesparta-infra`; this directory is `personal-infra`. The directory name wins.
