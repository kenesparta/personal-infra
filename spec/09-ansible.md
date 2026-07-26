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
| `docker`    | Engine + Compose plugin from Docker's apt repo, `web` network, GHCR login         | Do not use the distro `docker.io` package |
| `postgres`  | Install, `listen_addresses = '127.0.0.1'`, per-project DB + role, `scram-sha-256`, **2 GB tuning** | Passwords from vault; see A2 and AD-1     |
| `caddy`     | Compose stack, templated `Caddyfile`, origin-secret gate, named volume for `/data` | `/data` volume is load-bearing — see G8   |
| `deploy`    | One systemd `.service` + `.timer` per project                                     | Templated from `projects.yml`             |
| `backup`    | `pg_dump` script, bucket credentials, systemd timer                               | Writes to the Lightsail bucket            |
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

## 9.4 Conventions

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

**A6 — No shell scripts where a module exists.** `bootstrap.sh` is the sole permitted script, and only because
`user_data` requires one. Everything else uses Ansible modules; `command`/`shell` are last resorts and must carry
`creates:`, `removes:`, or `changed_when:` to stay idempotent.
