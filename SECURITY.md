# Security

Operational security for the one host this repository builds: a Lightsail instance (Ubuntu 24.04, Ubuntu Pro attached,
CIS Level 1 hardened) running four containerised services behind Caddy. This file is about **keeping it patched** —
what updates itself, what does not, how to find out, and how to act. The design-level security decisions live in the
spec: [§9.7](spec/09-ansible.md#97-os-security-updates-securityyml-rev-216) for this playbook,
[§12](spec/12-gotchas.md) for the failure modes, [AD-11/G21](spec/03-decisions.md) for the one static credential on the
box.

```bash
make security/check    # what is pending, what is held back, is a reboot due — read-only
make security/apply    # install the pending security updates; never reboots
```

Both need only SSH and a Terraform output for the IP. Neither reads the Ansible vault, so `make security/check` costs
nothing but the round trip — run it whenever you wonder.

---

## What patches itself

`unattended-upgrades`, installed and configured by the `common` role, every night via `apt-daily-upgrade.timer`. Its
policy is [`52personal-infra.j2`](ansible/roles/common/templates/52personal-infra.j2), and every line of it is a
decision:

| Setting                                            | Effect                                                              |
|----------------------------------------------------|---------------------------------------------------------------------|
| `Allowed-Origins: -security`, `ESMApps`, `ESM`     | Security pockets only — including both Ubuntu Pro ESM pockets        |
| `Package-Blacklist: docker-ce, docker-ce-cli, containerd.io` | Docker is never upgraded unattended (see below)             |
| `Automatic-Reboot "false"`                          | Never reboots on its own                                             |
| `Remove-Unused-Kernel-Packages "true"`             | Old kernels are cleaned up, so `/boot` cannot fill                   |

Security-only, not `-updates`: this host has no second node to fail over to (C8), so the appetite for an automatic
upgrade breaking a service at 06:00 is zero.

## What does not

Three gaps, all deliberate, all invisible unless you go looking. `make security/check` reports the first two.

**1. Docker.** `docker-ce`, `docker-ce-cli` and `containerd.io` are blacklisted, because an unattended daemon restart
takes all four services down mid-request, unwatched. The consequence is that the component *most* exposed — Caddy's
ports 80 and 443 are open to the world — sits on a runtime nothing patches automatically. This is [G26](spec/12-gotchas.md); upgrading it
is a manual act, below.

**2. The kernel, and anything else needing a reboot.** Updates install; the running kernel keeps running until someone
reboots, and so do any daemons still holding the old libraries open. `make security/check` reports both — comparing the
running kernel against the newest installed one rather than trusting `/var/run/reboot-required`, which is a tmpfs file
written by a package hook and is routinely absent on a host that genuinely needs rebooting (G27).

**3. Container userland.** Every project ships its own base image and its own OpenSSL. `apt` on the host never touches
them. They are patched by rebuilding the image in the project's own repository and pushing to GHCR — the deploy timer
picks it up within ten minutes (A5). A host with zero pending updates says nothing at all about the four containers
running on it.

---

## Checking

```bash
make security/check
```

Seven lines, each answering something the others do not:

```
pending security updates ..... 3
                               libc6 libssl3t64 openssh-server
held back by the Docker pin .. docker-ce containerd.io
reboot flag .................. set — linux-image-7.0.0-1011-aws libc6
running kernel ............... 7.0.0-1009-aws (STALE — 7.0.0-1011-aws is installed and waiting)
services on old libraries .... 7 — dbus.service docker.service systemd-logind.service …
esm-apps / esm-infra / std ... 2 / 0 / 3
nightly updater .............. enabled, last ran Sun 2026-08-30 06:14:22 UTC
read-only — re-run with `make security/apply` to install the above
```

- **pending** — what `unattended-upgrade --dry-run` would install *right now*. Usually zero: the timer ran last night.
  A non-empty list means an advisory landed since then.
- **held back by the Docker pin** — G26 made visible. Not urgent by default, but it is the only place this appears.
- **reboot flag** — `/var/run/reboot-required`, and which packages asked for it.
- **running kernel** — the running kernel against the newest installed one, from `needrestart`. This is the line that
  matters: the flag above lives in a tmpfs and depends on a hook having fired, so its *absence* proves nothing (G27).
  This host sat two kernel revisions behind with no flag set for 31 days.
- **services on old libraries** — long-running processes still mapping deleted `.so` files after an upgrade. A reboot
  clears the list; so does restarting each named service, if you would rather not reboot.
- **esm-apps / esm-infra / std** — from `pro security-status`. Counts by pocket; the ESM ones are what the Pro
  attachment buys and are the reason `harden.yml` runs `pro attach` at all.
- **nightly updater** — if this ever says `disabled`, every number above it is a snapshot of a host that has stopped
  patching itself, and that is the finding, not the package list.

## Applying

```bash
make security/apply
```

Runs the same `unattended-upgrade` binary the nightly timer runs — not `apt upgrade`. That matters: it inherits the
security-only origins and the Docker pin from `52personal-infra` rather than restating them, so the manual path and
the automatic path cannot drift apart (spec §9.7).

It does not reboot, and it does not touch Docker. If it loses a race with the nightly timer it fails on the dpkg lock;
re-run it. Nothing is left half-applied, because dpkg holds the lock for the whole transaction.

## Rebooting

Deliberate, and never by a playbook. When either `reboot flag` is set or `running kernel` says `STALE`:

```bash
aws lightsail create-instance-snapshot --instance-name kenesparta-host \
  --instance-snapshot-name pre-reboot-$(date +%F)          # if the kernel changed
ssh ubuntu@HOST sudo reboot
```

Then confirm the estate came back — Docker starts on boot and Compose restarts its containers, but "should" is not
"did":

```bash
ssh ubuntu@HOST docker ps --format '{{.Names}}\t{{.Status}}'
ssh ubuntu@HOST sudo nft list table inet personal_infra_guard   # G16 — must exist, or containers can read the bucket credentials
make configure                                                   # must still report 0 changed (A1)
```

The metadata guard is worth checking by name. It is ordered before `docker.service` and comes back on its own, but it
is also the single rule standing between a compromised application container and every project's database dumps.

## Upgrading Docker

Manual, scheduled, watched — the whole point of the blacklist is that this never happens by surprise.

```bash
make security/check                                    # note the held-back versions
ssh ubuntu@HOST sudo apt-get install --only-upgrade docker-ce docker-ce-cli containerd.io
ssh ubuntu@HOST docker ps --format '{{.Names}}\t{{.Status}}'
```

`live-restore` (set in the `docker` role's `daemon.json`) keeps containers up across a **daemon** restart but not
across a **containerd** restart, so expect them to bounce when `containerd.io` is in the set. Caddy's `/data` volume
and the Postgres named volume survive it; both are load-bearing (G8), so do not reach for `docker compose down -v` if
something looks wrong afterwards.

## Container images

Not this repository's job, and not `make configure`'s either (A5). A project is patched by rebuilding its image with a
current base and pushing to `ghcr.io/kenesparta/<project>`; `personal-infra-deploy@<name>.timer` pulls it within ten
minutes. To force it:

```bash
ssh ubuntu@HOST sudo systemctl start personal-infra-deploy@blog.service
ssh ubuntu@HOST sudo journalctl -u personal-infra-deploy@blog.service -n 50
```

---

## The rest of the posture, in one place

Not update-related, but this is where people look. Each is specified elsewhere; the pointer is the point.

| Surface                | State                                                                                          |
|------------------------|------------------------------------------------------------------------------------------------|
| CIS Level 1            | Applied via `usg fix` with the G18 tailoring — `make harden` only, never `site.yml` (A4)        |
| Inbound firewall       | 80 and 443 open by necessity; 22 restricted to `ssh_allowed_cidrs`, never `0.0.0.0/0` (§5.5)   |
| Origin protection      | Caddy 403s anything without the `X-Origin-Verify` header — application-layer, not network (AD-8)|
| Instance metadata      | Dropped for containers by an nftables table of its own, `personal_infra_guard` (G16)             |
| Brute force            | `fail2ban`, sshd jail only; deliberately none for Caddy — it would ban CloudFront edge nodes    |
| Host AWS credentials   | Exactly one static key, the CloudWatch logs writer, root-only (AD-11, G21)                      |
| Backups                | Nightly `pg_dump` to the Lightsail bucket via instance metadata — no credential on disk (G5)     |
| Secrets                | `ansible-vault` for the host, `sops`+`age` for Terraform — two mechanisms, not merged (§9.4)     |
| DNSSEC                 | Signed **and** validated on all three zones; `dig +dnssec <zone> @1.1.1.1` must show `ad` (§5.6.1) |

## Rotating the GHCR token

The one credential that expires on GitHub's schedule rather than ours. `read:packages` and nothing else (AD-10).
Rotation is one-sided — update the vault, then push it to the host:

```bash
EDITOR=vim make vault/edit      # vault_ghcr_token
make vault/check                # still encrypted?
make configure                  # the docker role re-runs `docker login` every time, on purpose
```

The `docker login` in the `docker` role is deliberately unconditional: it is also the only check that the token has not
expired or been revoked. Without it the failure is quiet in the way that matters — a dead PAT fails the *pull*, so
`personal-infra-deploy@<name>.service` fails on every tick while the running container keeps serving happily, and
nothing at this scale alerts on a failing timer. Deploys stop landing and the site stays up, which is the combination
nobody notices for a week.

## Reporting a vulnerability

This is personal infrastructure with a single operator. Mail <kenesparta@pm.me>; please do not open a public issue for
anything exploitable.
