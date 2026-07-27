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

- [ ] Seed `ghcr.io/kenesparta/kenespartadev:latest` by retagging the live ECR image (one-time bridge — the deploy
      role's first `docker compose up` pulls it, and CI does not publish to GHCR until Phase 5)
- [ ] `caddy_acme_staging: true` (G8): the `origin.*` records do not exist until Phase 6, so real issuance cannot
      succeed yet and failed validations must land on the staging budget
- [ ] `common`, `docker`, `postgres`, `caddy`, `deploy`, `backup` roles
- [ ] Backup bucket and `pg_dump` timer
- **Verify:** `make configure` twice; the second run reports zero `changed`

## Phase 4 — Data migration

- [ ] `pg_dump -Fc` the Lightsail managed database `personal-projects` (PostgreSQL **18.4** — see G14)
- [ ] Restore into the host Postgres container, `blog` database
- [ ] Confirm the container's `DATABASE_URL` resolves `postgres:5432` on the `web` network (AD-3; **not** `127.0.0.1`,
      which inside a bridge-networked container is its own namespace)
- **Verify:** row counts match; the app renders posts from the host database
- *As executed (2026-07-27):* the managed database was deleted by the operator immediately after taking final dumps,
  *before* this phase ran — so "row counts match" was verified dump→scratch-restore against dump→host-restore
  (identical), not against the live source. The final dumps of every database (including `budget-assistant`, which has
  no `projects.yml` entry) are archived under `s3://kenesparta-infra-backups/managed-db-final/`.

## Phase 5 — Registry cutover

- [ ] Rewrite `publish-image.yml` to build and push to GHCR with `GITHUB_TOKEN`
- [ ] Tag a release; confirm the systemd timer pulls and starts it
- **Verify:** `docker compose ps` shows the new image running, pulled without manual intervention

## Phase 6 — Edge cutover (the only user-visible moment)

- [ ] Add `origin.kenesparta.dev` A → static IP; flip `caddy_acme_staging` to false and re-run `make configure`;
      confirm Caddy issues its certificate
- [ ] The distribution's `custom_header` reads `ORIGIN_VERIFY_SECRET` from `secrets/prod.enc.env` — seeded in Phase 3
      with the same value as `vault_origin_secret` (G13)
- [ ] Repoint the app CloudFront origin from the container service to `origin.kenesparta.dev`, with the secret header
- **Verify:** `kenesparta.dev` serves from the instance; a direct request to `origin.kenesparta.dev` without the secret
  returns 403

## Phase 7 — Teardown

- [x] Destroy the container service and deployment version — *2026-07-27, with the sops data block moved from
      `legacy.tf` into `cloudfront.tf` (its consumers) first. The `budget-bot` estate went separately the same day,
      destroyed via its own retired state (15 resources) as part of adopting that project into `projects.yml`.*
- [x] Destroy the ECR repository and its policies; trim the CI role to the CDN write only — *the repository had to be
      emptied first (`batch-delete-image`); the migrated resource carried no `force_delete`*
- [x] Delete the Lightsail managed database (**only after Phase 4 is verified**) — *done early, out of band, by the
      operator on 2026-07-27 after taking final dumps; see the Phase 4 note*
- [x] Delete `kenesparta.dev/tf` from the application repository — *2026-07-27; the old state object
      `dns/prod/kenesparta.dev` stays in S3 as the frozen rollback point (G10)*
- **Verify:** `terraform plan` clean; monthly cost trending toward the model in [§14](14-cost.md) — *plan clean
  2026-07-27, `-detailed-exitcode` 0*

## Phase 8 — Hardening (deliberate, separate)

- [x] Snapshot first, `make harden`, verify SSH in a second terminal **before closing the first** — *2026-07-27;
      snapshot `pre-harden-2026-07-27`, the "first terminal" an SSH ControlMaster session held open throughout, a fresh
      connection verified before it closed*
- [x] Re-run `make configure` to confirm hardening broke nothing — *run 1 `changed=1`, run 2 `changed=0` (A1 holds)*
- *As executed (2026-07-27):* the first `usg fix` applied the **stock** profile (111 failing rules remediated) and its
  host-firewall chapter promptly broke the design: `nftables.service` enabled and started with a `flush ruleset`
  config — Docker's chains and the G16 guard wiped live — `ufw` purged, and `net.ipv4.ip_forward` forced to 0, killing
  container-outbound traffic while inbound survived only via `docker-proxy`. Repaired in place (service disabled, guard
  reloaded, sysctls reverted, dockerd restarted under live-restore — zero container downtime), then **G18** was added
  and `usg fix` re-ran with the tailoring file (22 rules deselected); the marker records the tailored profile.
  Rebooted afterwards for the kernel parameters and to prove the boot order: guard active before containers,
  `nftables.service` inactive, forwarding restored by dockerd, all four containers and both sites up.

## Phase 9 — Validation

- [ ] **Restore a `pg_dump` into a scratch database.** An untested backup is not a backup
