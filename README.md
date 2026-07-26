# personal-infra

Terraform + Ansible for a single-host application server on AWS Lightsail, and the consolidated Terraform state for the
whole `kenesparta.dev` AWS account.

Up to four containerized Rust services share one instance behind Caddy, with a self-hosted PostgreSQL and off-host
backups. Images are built by GitHub Actions, published to GHCR, and **pulled** by a systemd timer — nothing pushes to
this host.

> **[`spec/`](spec/) is the source of truth.** It records every architecture decision, what was rejected, and why —
> one file per numbered section, indexed by [`spec/README.md`](spec/README.md). Read it before changing anything; if you
> find a gap, amend the spec first, then implement. This README is the operator's entry point, not the design.

---

## Status: mid-migration

This repository is absorbing a working estate from [`../kenesparta.dev`](../kenesparta.dev), which today runs the site
on a Lightsail **Container Service** fronted by CloudFront, pulling a private ECR image, backed by a Lightsail
**managed** PostgreSQL.

| Phase | What                                            | State |
|-------|-------------------------------------------------|-------|
| 0     | State consolidation (copy the state object)     | written, **not applied** |
| 1     | Instance, static IP, firewall, snapshots        | written, **not applied** |
| 2     | Verify the bootstrap                            | — |
| 3     | Ansible: common, docker, postgres, caddy, deploy, backup | — |
| 4     | Data migration: managed Postgres → host         | — |
| 5     | Registry cutover: ECR → GHCR                    | — |
| 6     | Edge cutover: CloudFront origin swap            | — |
| 7     | Teardown: container service, ECR, `kenesparta.dev/tf` | — |
| 8     | CIS hardening (deliberate, separate)            | — |
| 9     | Validation: restore a backup for real           | — |

The site stays up throughout. The apex `A ALIAS → CloudFront` record never changes, so the host cutover in Phase 6 is a
CloudFront **origin swap**, not a DNS change — no propagation wait, and rollback is the same one-line change in reverse.

---

## Architecture

```
                    kenesparta.dev                cdn.kenesparta.dev
                          │                              │
                    A ALIAS │                       A ALIAS │
                          ▼                              ▼
                  CloudFront (ACM)                CloudFront (ACM)
                          │  https-only                  │
                          │  + X-Origin-Verify           ▼
                          ▼                        S3 (OAC, private)
           origin.kenesparta.dev ──A──► static IP
                                          │
                              ┌───────────┴───────────┐
                              │   Lightsail instance   │
                              │   small_3_0 · 2 GB     │
                              │                        │
                              │   Caddy :80/:443       │  Let's Encrypt (HTTP-01)
                              │     │  403 without     │  on the origin-* names
                              │     │  the secret      │
                              │     ▼                  │
                              │   blog:3000  …up to 4  │  ← GHCR, pulled by systemd timer
                              │     │                  │
                              │   postgres 127.0.0.1   │  ← one DB + role per project
                              │     │                  │
                              └─────┼──────────────────┘
                                    ▼
                            Lightsail bucket (pg_dump)
```

**Why two certificates.** An ACM certificate can never be installed on a Lightsail instance — standard ACM public certs
are non-exportable, and Lightsail's own certificate service attaches only to load balancers, container services and CDN
distributions. So ACM terminates at CloudFront and Caddy holds a separate Let's Encrypt cert for the origin. See spec
AD-8 and G2.

**Why one distribution per project.** CloudFront routes by path pattern, not by `Host`, so a single distribution cannot
fan several hostnames out to several backends. Distributions are billed per request and per GB, not per distribution, so
this costs nothing extra.

**Why the origin is publicly reachable.** Lightsail firewalls take plain CIDR lists and cannot reference CloudFront's
`origin-facing` managed prefix list, whose ranges rotate. The origin is gated at the application layer instead — Caddy
403s anything without the shared `X-Origin-Verify` header (G11).

---

## Prerequisites

| Tool                | Why                                                  |
|---------------------|------------------------------------------------------|
| Terraform ≥ 1.10    | Native S3 state locking (`use_lockfile`); CI pins 1.15.8 |
| AWS CLI v2          | SSO login, state seeding, Lightsail lookups          |
| Ansible             | Host configuration (Phase 3 onward)                  |
| `sops` + `age`      | Decrypts `secrets/prod.enc.env`                      |

Also needed:

- **age private key** at `~/.config/sops/age/keys.txt` (the Makefile exports `SOPS_AGE_KEY_FILE` to point there)
- **SSH keypair** at `~/.ssh/personal-infra` / `.pub` — the public half is authorized on the instance

```bash
cp terraform/.env.example terraform/.env               # SSO profile
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# set ssh_allowed_cidrs:  curl -s https://checkip.amazonaws.com
make login
```

`ssh_allowed_cidrs` must never contain `0.0.0.0/0`; a variable validation rejects it, because the firewall resource is
authoritative and a wildcard there exposes SSH globally.

---

## Running it

```bash
make help          # list targets
```

### Phase 0 — state consolidation

The old state already contains every resource that is moving, so it is **copied**, not re-imported. Resource addresses
are preserved verbatim, which is why there are no `import` blocks anywhere in this repo.

```bash
make state/seed    # copy old state object → new key (prompts; source is never modified)
make plan/phase0   # THE GATE — must report "No changes"
```

`plan/phase0` moves the Phase 1 files aside and plans the migrated configuration alone, so it answers exactly one
question: *did the state copy land correctly?* It uses `-detailed-exitcode` — **0 = pass**, 2 = drift.

**Do not proceed past a dirty gate.** The usual causes are a provider version bump (`aws` is pinned to `6.15.0`
precisely to avoid this) or a changed default for `project` / `owner` / `environment`, which feed `common_tags` on ~20
resources.

`terraform/.terraform.lock.hcl` **is committed** — deliberately, and unlike the old `kenesparta.dev/tf`, which ignored
it. The gate depends on provider determinism, and `carlpett/sops` is constrained only to `~> 1.2`; the lock file is the
only thing actually pinning it to 1.4.1. It carries hashes for both `darwin_arm64` and `linux_amd64`, so an `init` from
Linux won't fail on a missing checksum. After changing a provider version:

```bash
terraform -chdir=terraform providers lock -platform=darwin_arm64 -platform=linux_amd64
```

### Phase 1 — the host

```bash
make plan          # expect: 5 to add, 0 to change, 0 to destroy
make apply
ssh ubuntu@$(terraform -chdir=terraform output -raw static_ip)
```

Verify the blueprint and bundle IDs first — they change over time, and Lightsail supports only a subset of AZs:

```bash
aws lightsail get-blueprints --query 'blueprints[?platform==`LINUX_UNIX`].[blueprintId,name]' --output table
aws lightsail get-bundles    --query 'bundles[].[bundleId,ramSizeInGb,price]' --output table
aws lightsail get-regions --include-availability-zones --query 'regions[?name==`us-east-1`].availabilityZones[].zoneName'
```

### Phase 3 onward — Ansible

Not yet written. The targets exist and will work once `ansible/` lands:

```bash
make check-ssh     # ansible -m ping   (Phase 2 gate)
make configure     # site.yml — everything except hardening
make harden        # harden.yml — SNAPSHOT FIRST, see below
```

`make inventory` regenerates `ansible/inventory/hosts.ini` from `terraform output -raw static_ip`. Terraform owns the
IP; Ansible reads it. It is deliberately *not* a `local_file` resource — that would put a generated local file under
state management and couple `terraform destroy` to Ansible's working tree.

---

## Adding a project

Edit `projects.yml`. One file drives origin DNS records, CloudFront distributions, Caddy vhosts, Postgres databases, and
deploy timers — Terraform reads it with `yamldecode`, Ansible with `vars_files`. Neither tool keeps its own copy.

```yaml
- name: api
  hostname: api.kenesparta.dev       # CloudFront alias (already covered by the wildcard ACM cert)
  origin: origin-api.kenesparta.dev  # A → static IP; must resolve DIRECTLY to the box for HTTP-01
  image: ghcr.io/kenesparta/api
  port: 3001
  database: api
```

The ceiling is **four services**. RAM is the binding constraint on a 2 GB host: ~350 MB OS + Docker, ~400 MB tuned
Postgres, ~50 MB Caddy, ~100 MB per service. Growing past four means resizing to `medium_3_0`, which is a
stop / change-bundle / start on a snapshot — minutes of downtime, no redesign.

---

## Things that will hurt you

Full list in [`spec/12-gotchas.md`](spec/12-gotchas.md). The ones with no undo:

- **Never run `terraform destroy` in `../kenesparta.dev/tf`.** That state owns the Route 53 zones, their DNSSEC
  key-signing keys, and the KMS keys. Destroying it breaks **mail delivery to the Proton addresses**, not just the
  website, and KMS keys enter an unshortenable 7-day deletion window. Retiring that directory means *deleting it* after
  Phase 0 passes — never destroying it.
- **`user_data` is `ForceNew`.** Editing `terraform/bootstrap.sh` destroys and recreates the instance, databases
  included. It is minimal by design so it never needs to change. Treat any plan showing instance replacement as data
  loss.
- **The firewall resource is authoritative.** `aws_lightsail_instance_public_ports` replaces the entire rule set rather
  than merging. Removing the port 22 block removes SSH.
- **Hardening can lock you out.** `usg fix cis_level1_server` rewrites SSH config, file permissions and kernel
  parameters. Snapshot first, then verify SSH from a *second* terminal before closing the first.
- **Let's Encrypt limits are per registered domain** — 50 certs/week shared across every `origin-*` name. Caddy's
  `/data` volume must persist across container recreation, and `.dev` is HSTS-preloaded, so a TLS error makes the site
  unreachable rather than merely degraded. Iterate against LE staging.
- **The origin secret is a two-sided rotation.** It lives in Terraform state (`custom_header`) and Ansible Vault (Caddy's
  comparison). Change Terraform first, then Ansible — the reverse order 403s every request in the gap.

---

## Secrets

Two mechanisms, deliberately not merged:

- **sops + age** — `secrets/prod.enc.env`, committed encrypted, read by Terraform's sops provider. Copied from the
  application repo; same age recipient, so it decrypts identically.
- **ansible-vault** — `ansible/group_vars/vault.yml` holds Postgres passwords, the GHCR PAT, and the origin secret.

No secret is ever a Terraform output, and none may appear in `terraform.tfvars.example`.

### Working with `secrets/prod.enc.env`

Go through `make` rather than `sops` directly — the Makefile pins `SOPS_AGE_KEY_FILE`, which does not match sops'
default on macOS. `make help` lists these under *Secrets*; `SECRETS_FILE=…` targets a different file.

```bash
make secrets/check                  # encrypted? decryptable here? — pre-flight for `make plan`
make secrets/keys                   # key names only, no values
make secrets/get KEY=DATABASE_URL   # one value
make secrets/show                   # the whole file, decrypted, to stdout

make secrets/edit                   # $EDITOR on the plaintext; re-encrypts on save
make secrets/set KEY=ORIGIN_VERIFY_SECRET
make secrets/unset KEY=OLD_THING
```

`secrets/set` takes the value on **stdin**, never on the command line — hidden prompt at a terminal, piped input
otherwise — so a secret never reaches shell history or `ps`.

### Changing who can decrypt

Recipients live in `.sops.yaml`, but editing it alone changes nothing: the file's data key has to be re-encrypted
afterwards.

```bash
make secrets/recipients                 # who can decrypt, and whether your key is among them
make secrets/recipient-add AGE=age1…    # then:  make secrets/updatekeys
make secrets/recipient-rm  AGE=age1…    # then:  make secrets/updatekeys && make secrets/rotate
```

Removal needs both. `updatekeys` only drops the key from the file's metadata — the removed holder already knows the
data key of every committed version, and `secrets/rotate` (a *new* data key) is what actually revokes access.

---

## Cost

| Line item                           | Current    | Target     |
|-------------------------------------|------------|------------|
| Lightsail Container Service (nano)  | $7.00      | —          |
| Lightsail Small instance            | —          | $12.00     |
| Lightsail managed PostgreSQL        | ~$15.00    | —          |
| Auto-snapshots (60 GB, incremental) | —          | ~$1.50     |
| Backup bucket (5 GB)                | —          | $1.00      |
| ECR storage                         | ~$1.00     | —          |
| Route 53 zones (×2) + DNSSEC KMS    | $3.00      | $3.00      |
| CloudFront (app + cdn) + S3         | ~$1.60     | ~$1.60     |
| **Total**                           | **~$27.60**| **~$19.10**|

The migration *saves* ~$8.50/mo: retiring the managed database more than pays for the instance.

---

## Where things live

| File            | Contains                                                        |
|-----------------|-----------------------------------------------------------------|
| `spec/`         | Source of truth — decisions, rejected alternatives, phases, gotchas (index: `spec/README.md`) |
| `CLAUDE.md`     | Guidance for Claude Code sessions                               |
| `projects.yml`  | The project fan-out, shared by both tools                       |
| `terraform/legacy.tf` | Container service + ECR — everything deleted in Phase 7   |
| `terraform/main.tf`   | The new host (Phase 1)                                    |
