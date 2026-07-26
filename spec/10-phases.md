# 10. Migration Phases

Each phase ends with a verifiable outcome and is independently revertible. The site stays up throughout: the apex
`ALIAS → CloudFront` record never changes, so the cutover is a CloudFront origin swap, not a DNS change.

## Phase 0 — State consolidation (no infrastructure change)

- [ ] `aws s3 cp s3://tf.kenesparta.dev/dns/prod/kenesparta.dev s3://tf.kenesparta.dev/infra/prod/terraform.tfstate`
- [ ] Port the surviving `.tf` files into `personal-infra/terraform/` under **identical resource addresses**
- **Verify:** `terraform plan` reports **no changes**. This is the gate — do not proceed until it is clean.

## Phase 1 — Compute (additive)

- [ ] `bootstrap.sh` — **written now, not in Phase 2.** `user_data` is `ForceNew` (G4), so it must be correct at
      creation; adding it later replaces the instance. Limited to: apt update, `python3` present.
- [ ] Key pair from `~/.ssh/personal-infra.pub`, instance, static IP + attachment, firewall, auto-snapshot
- **Verify:** SSH connects using the static IP; `nmap` from an unlisted IP shows 22 filtered, 80/443 open

## Phase 2 — Verify the bootstrap

- [ ] Confirm `user_data` actually executed (`/var/log/bootstrap-done` exists), not merely that the host pings
- **Verify:** `make check-ssh` (`ansible -m ping`) succeeds
- **Do not** add package installs to `bootstrap.sh` to fix anything found here — anything beyond "Ansible can connect"
  belongs in a role, or G4 makes the fix a host rebuild.

## Phase 3 — Configuration (Ansible)

- [ ] `common`, `docker`, `postgres`, `caddy`, `deploy`, `backup` roles
- [ ] Backup bucket and `pg_dump` timer
- **Verify:** `make configure` twice; the second run reports zero `changed`

## Phase 4 — Data migration

- [ ] `pg_dump` the Lightsail managed database
- [ ] Restore into the host Postgres, `blog` database
- [ ] Point the container's `DATABASE_URL` at `127.0.0.1`
- **Verify:** row counts match; the app renders posts from the host database

## Phase 5 — Registry cutover

- [ ] Rewrite `publish-image.yml` to build and push to GHCR with `GITHUB_TOKEN`
- [ ] Tag a release; confirm the systemd timer pulls and starts it
- **Verify:** `docker compose ps` shows the new image running, pulled without manual intervention

## Phase 6 — Edge cutover (the only user-visible moment)

- [ ] Add `origin.kenesparta.dev` A → static IP; confirm Caddy issues its certificate
- [ ] Repoint the app CloudFront origin from the container service to `origin.kenesparta.dev`, with the secret header
- **Verify:** `kenesparta.dev` serves from the instance; a direct request to `origin.kenesparta.dev` without the secret
  returns 403

## Phase 7 — Teardown

- [ ] Destroy the container service and deployment version
- [ ] Destroy the ECR repository and its policies; trim the CI role to the CDN write only
- [ ] Delete the Lightsail managed database (**only after Phase 4 is verified**)
- [ ] Delete `kenesparta.dev/tf` from the application repository
- **Verify:** `terraform plan` clean; monthly cost trending toward the model in [§14](14-cost.md)

## Phase 8 — Hardening (deliberate, separate)

- [ ] Snapshot first, `make harden`, verify SSH in a second terminal **before closing the first**
- [ ] Re-run `make configure` to confirm hardening broke nothing

## Phase 9 — Validation

- [ ] **Restore a `pg_dump` into a scratch database.** An untested backup is not a backup
