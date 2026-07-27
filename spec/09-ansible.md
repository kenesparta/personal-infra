# 9. Ansible Specification

## 9.1 Inventory handoff

Terraform is the source of truth for the IP; Ansible reads it rather than duplicating it.

```make
inventory:
	@printf '[app]\n%s ansible_user=ubuntu\n' \
	  "$$(cd terraform && terraform output -raw static_ip)" > ansible/inventory/hosts.ini

configure: inventory
	cd ansible && ansible-playbook -i inventory/hosts.ini site.yml

harden: inventory
	cd ansible && ansible-playbook -i inventory/hosts.ini harden.yml
```

Deliberately not using `local_file` in Terraform to write the inventory — that puts generated local files under state
management and couples `terraform destroy` to Ansible's working tree.

## 9.2 Roles

| Role        | Responsibility                                                                    | Notes                                     |
|-------------|-----------------------------------------------------------------------------------|-------------------------------------------|
| `common`    | apt cache, base packages, `unattended-upgrades`, timezone, `fail2ban`             | Runs first, no dependencies               |
| `docker`    | Engine + Compose plugin from Docker's apt repo, `web` network, GHCR login, metadata guard | Do not use the distro `docker.io` package; guard is G16 |
| `postgres`  | Compose stack on `web`, no published port, per-project DB + role, `scram-sha-256`, **2 GB tuning** | Passwords from vault; see A2, AD-1, AD-3  |
| `caddy`     | Compose stack, templated `Caddyfile`, origin-secret gate, named volume for `/data` | `/data` volume is load-bearing — see G8   |
| `deploy`    | One systemd `.service` + `.timer` per project                                     | Templated from `projects.yml`             |
| `backup`    | `pg_dump` script, systemd timer — **no credentials** (G5)                         | Writes to the Lightsail bucket            |
| `hardening` | `pro attach`, `pro enable usg`, `usg fix`                                          | **Separate playbook only** — see A4       |

## 9.3 Caddy origin gate

Every vhost rejects requests that did not come through CloudFront:

```
origin.kenesparta.dev {
    @noSecret not header X-Origin-Verify "{$ORIGIN_SECRET}"
    respond @noSecret 403
    reverse_proxy blog:3000
}
```

The secret is rendered from Ansible Vault. Rotating it requires changing both the Terraform `custom_header` and the
vault value — Terraform first, then Ansible, or requests 403 in the gap.

## 9.4 Vault contents

`group_vars/vault.yml`, `ansible-vault`-encrypted (A2). `group_vars/vault.yml.example` is the committed, plaintext
template; it carries key names only and never a value. Both playbooks load it with an explicit `vars_files` entry:
`group_vars/<name>.yml` only auto-loads for an inventory group called `<name>`, and no group named `vault` exists —
relying on the convention would silently load nothing.

| Key                            | Used by    | Notes                                                          |
|--------------------------------|------------|----------------------------------------------------------------|
| `vault_postgres_superuser_password` | `postgres` | The container's `POSTGRES_PASSWORD`                        |
| `vault_postgres_passwords`     | `postgres`, `deploy` | Map of `<project name>` → password, one per `projects.yml` entry |
| `vault_origin_secret`          | `caddy`    | Must equal the CloudFront `custom_header` value (G13)          |
| `vault_ghcr_username` / `vault_ghcr_token` | `docker` | GHCR PAT, `read:packages` scope only (AD-10)       |
| `vault_ubuntu_pro_token`       | `hardening`| Only needed by `harden.yml`                                    |

The backup path holds **no** credential: the instance is attached to the bucket with Lightsail resource access, so the
AWS CLI resolves short-lived credentials from instance metadata (G5, §5.7). This is why the `docker` role installs the
metadata guard — without it those credentials are readable by every container (G16).

## 9.5 The Postgres stack

Per AD-3 Postgres is a container on `web`, not an apt package. Consequences the roles must honour:

- **No published port** — applications reach it as `postgres:5432` by Docker DNS; the host shows nothing on 5432.
- **Tuning is passed as `-c` flags** in the Compose `command`, not via `postgresql.conf`. The official image does not
  read a `conf.d` directory, and `-c` keeps the effective values visible in `docker inspect`. Values come from
  `postgres_settings` in `group_vars/all.yml` and implement AD-1's 2 GB budget.
- **The data directory is a named volume.** Like Caddy's `/data` (G8) it is load-bearing: `docker compose down -v`
  destroys the databases.
- **Administration goes through `docker exec`.** The image's generated `pg_hba.conf` leaves the in-container unix socket
  on `trust` and every TCP connection on `scram-sha-256`, so `docker exec postgres psql -U postgres` needs no password
  while nothing on the network can connect without one. Reaching that socket already requires root on the host.
- **The major version must be ≥ the managed source** — see G14.

## 9.6 Conventions

**A1 — Idempotency is the contract.** Every role must produce zero `changed` on a second consecutive run. This is an
acceptance criterion, not an aspiration.

**A2 — Secrets live in Vault.** Postgres role passwords, the GHCR token, and the origin secret go in
`group_vars/vault.yml`, encrypted with `ansible-vault`. Never in plaintext vars, never committed unencrypted.

**A3 — Handlers, not restarts.** Config changes notify handlers; roles never unconditionally restart services.

**A4 — Hardening is a separate playbook, run deliberately.** `usg fix cis_level1_server` alters SSH configuration, file
permissions, and kernel parameters, and can lock you out. It must never run as part of `site.yml`.

Required procedure: snapshot the instance, run `harden.yml`, verify SSH from a second terminal *before closing the
first*, then re-run `site.yml` to confirm nothing broke. Wrap `usg fix` with a `creates:` marker file so re-runs are
no-ops.

**A5 — Ansible does not deploy applications.** It installs the timer that pulls images. `ansible-playbook` should be
something you run rarely, while deploys happen continuously without it.

**A6 — No shell scripts where a module exists.** `bootstrap.sh` is the sole permitted script *in the provisioning path*,
and only because `user_data` requires one. Everything else Ansible does uses Ansible modules; `command`/`shell` are last
resorts and must carry `creates:`, `removes:`, or `changed_when:` to stay idempotent.

*Clarified in rev 2.1:* this governs how Ansible does its work, not what runs on the host afterwards. A program a
systemd unit executes on a timer is an artefact Ansible **templates**, not a step Ansible **runs**, and no module
replaces it — `pg-backup.sh` (the `backup` role) is such a program, because systemd `ExecStart=` has no shell and so
cannot redirect output or build a timestamped object key. Deploy it with `template:` and keep the logic in the file
rather than in a quoted `sh -c` inside a unit.
