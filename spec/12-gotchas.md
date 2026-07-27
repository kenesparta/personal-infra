# 12. Known Constraints & Gotchas

**G1 — Lightsail region availability.** Lightsail exists in a subset of AWS regions and a subset of AZs within them.
Validate `availability_zone` before applying.

**G2 — ACM certificates cannot be installed on a Lightsail instance.** Standard ACM public certs are non-exportable;
Lightsail's own certificates attach only to load balancers, container services, and CDN distributions. The instance
always needs Let's Encrypt. (AWS added *exportable* ACM public certificates in 2025 — paid, with manual redeployment on
renewal. Verify pricing and renewal mechanics before considering it; Caddy + LE is free and zero-touch.)

**G3 — `aws_lightsail_instance_public_ports` is authoritative.** It replaces the entire firewall rule set, not merges
into it. Omitting port 22 removes SSH access. Every required port must be present in the resource.

**G4 — `user_data` forces instance replacement.** Editing `bootstrap.sh` destroys and recreates the instance on the next
apply. With Ansible owning host configuration, `bootstrap.sh` should never need to change after Phase 2, so the trap is
largely defused. It is still live — treat any plan showing instance replacement as data loss unless a snapshot exists.
Lightsail also does not execute the script via its shebang: its own init wrapper inlines `user_data` and runs it under
`sh` (dash on Ubuntu), so a single bashism kills the entire script — `set -o pipefail` aborts dash with `Illegal
option`, and nothing after it runs (found in Phase 1: SSH worked, `/var/log/bootstrap-done` did not exist,
`cloud-init status` = error). `bootstrap.sh` is therefore `#!/bin/sh` and must stay POSIX-clean. A replacement forced
by a `user_data` fix also silently strips the instance-scoped attachments — static IP, firewall rules, bucket access —
while their unchanged state hides the loss (name-keyed references don't cascade), so rebuild with
`-replace=` on all three alongside the instance, never with a bare apply.

**G4b — Ansible does not restore data.** A rebuilt host is configured, not repopulated. Postgres contents come from the
backup bucket, and that restore path is manual. Rehearse it before you need it.

**G5 — Lightsail instances cannot assume IAM roles — *except* for Lightsail buckets.** There is no instance profile, so
the box cannot get credentials for an arbitrary AWS API. This is the root cause of AD-10: there is no attachment for
ECR, so pulling from it would mean a long-lived key plus a timer refreshing the 12-hour token, and GHCR avoids both.

*Corrected in rev 2.2:* the original wording — "**any** AWS API access from the box needs a long-lived access key on
disk" — is too broad, and the backup path was built on that mistake. Lightsail buckets have a native equivalent of an
instance profile, **resource access**:

> Use resource access to grant full read and write access to a bucket and its objects for Lightsail instances. With
> resource access, you don't have to manage credentials like access keys.
> — [Control access to Lightsail buckets and objects](https://docs.aws.amazon.com/lightsail/latest/userguide/amazon-lightsail-understanding-bucket-permissions.html)

Attaching the instance (`aws_lightsail_bucket_resource_access`, spec §5.7) makes the AWS CLI on the box resolve
short-lived credentials from instance metadata, so `pg-backup.sh` needs no key at all. `aws_lightsail_bucket_access_key`
is therefore unused — which is just as well, since its `secret_access_key` is a plain `computed` attribute and would
land in state in cleartext.

Scope, precisely: the instance and bucket must be in the same Region, the instance must be running or stopped, and the
grant is **whole-bucket read and write** — it cannot be narrowed to a prefix or to read-only. It confers nothing beyond
that bucket. **See G16 before relying on it** — metadata credentials are reachable from containers, and closing that is
part of the design, not an optional extra.

**G6 — No custom AMIs.** Lightsail accepts only its own blueprints. Snapshots export to EC2 one-way and never import
back. Hardening must happen post-provision, not baked into an image.

**G7 — `.dev` is HSTS-preloaded.** Browsers refuse plaintext HTTP for this TLD entirely. A TLS misconfiguration makes
the site unreachable rather than degraded. Use Let's Encrypt's staging endpoint while iterating on origin certificates.

**G8 — Let's Encrypt rate limits.** 50 certificates per registered domain per week, counted across *all* subdomains —
the `origin-*` names share the `kenesparta.dev` budget with everything else. Caddy's `/data` volume must persist across
container recreation or repeated re-issuance can trigger a multi-day lockout.

**G9 — Static IP billing.** Free while attached to a running instance; charged (~$3.60/mo) if left allocated but
unattached. A partial `destroy` can leave one orphaned.

**G10 — Never `terraform destroy` in `kenesparta.dev/tf`.** That state owns the Route 53 zones, their DNSSEC
key-signing keys, and the KMS keys. Destroying it would break mail delivery to the Proton addresses, not merely the
website, and KMS keys enter a 7-day deletion window that cannot be shortened. Retirement means *deleting the directory*
after Phase 0 verifies the new state, never running destroy in it.

**G11 — CloudFront origins cannot be firewalled off on Lightsail.** Instance firewalls take plain CIDR lists and cannot
reference the `com.amazonaws.global.cloudfront.origin-facing` managed prefix list; those ranges rotate. The shared
`X-Origin-Verify` header is the only lockdown available, and it is an application-layer control, not a network one.

**G12 — CloudFront origins must be hostnames, not IP addresses.** This is why `origin-<project>` records exist at all.

**G13 — The origin secret is a two-sided rotation.** It lives in Terraform state (as a `custom_header`) and in Ansible
Vault (as the Caddy comparison value). Change Terraform first, then Ansible; the reverse order 403s every request in
between.

**G14 — The Postgres major version must be ≥ the managed source.** The Lightsail managed database `personal-projects`
runs **PostgreSQL 18.4**, so the container image is pinned to 18. `pg_restore` moves forward across majors, never
backward: a dump taken from 18.4 cannot be loaded into 16 or 17, and the failure appears at Phase 4 with the migration
already half-done. Use the Debian-based `postgres:18` image rather than an Alpine one — musl and glibc sort text
differently, and matching the source's glibc collation keeps index ordering and `ORDER BY` results identical after the
restore.

**G15 — `web` is a shared, flat network.** Every container on it can reach `postgres:5432` and attempt authentication;
per-project isolation is by role and password, not by network. This is the accepted cost of the single-Postgres design
(AD-3) at four services. Keep per-project passwords genuinely distinct, and remember that `REVOKE CONNECT … FROM PUBLIC`
on each database is what stops project A from reading project B's data.

**G16 — Instance metadata is reachable from containers, and that is how credentials leak.** Removing the backup access
key in favour of resource access (G5) moves the credential from a `0600` root-owned file to the metadata service — and
link-local traffic from a container is routed out through the host, so *any* container on a Docker bridge can ask
`169.254.169.254` for it and receive full read/write on the backup bucket. That is strictly worse than the file it
replaced, which containers could not read, and it would hand a compromised application container every project's
database dumps — precisely the data that `REVOKE CONNECT` (G15) stops it reading from Postgres.

The `docker` role closes this with **native nftables**, in a table of its own (`personal_infra_guard`) rather than a rule
in Docker's `DOCKER-USER` chain. The hook is `forward`, which is the path container→metadata traffic takes and *not* the
path the host's own traffic takes (`output`) — so `pg-backup.sh` keeps its credentials while containers get nothing.

Ubuntu 24.04's `iptables` is already the `nf_tables` backend (`iptables v1.8.10 (nf_tables)`), so this is not a change of
technology — only of interface. An independent table wins on three counts, all verified:

- **Docker cannot remove it.** Docker rebuilds its own chains on every daemon start; a `DOCKER-USER` rule has to be
  re-applied afterwards, whereas this table survives even a full `iptables -F`.
- **It can be ordered *before* `docker.service`**, because it needs nothing from Docker. A `DOCKER-USER` rule cannot
  exist until dockerd has built its chains, so that approach always leaves a boot-time window in which containers are
  running unguarded.
- **It does not depend on the `DOCKER-USER` chain existing**, so it keeps working if Docker's native nftables firewall
  backend is ever enabled.

In nftables a `drop` is final across every table at a hook, while an `accept` in one table does not stop others being
evaluated — verified: this DROP overrides an explicit `iptables -I OUTPUT … -j ACCEPT`. The priority (`filter - 10`) is
therefore belt-and-braces rather than load-bearing.

Two things to know:

- **`iptables -S` will not show this rule.** Anyone debugging with iptables tooling sees nothing and concludes there is
  no block. Use `nft list table inet personal_infra_guard`; the rule carries a `counter`, so a non-zero packet count is
  evidence that something in a container went looking for credentials.
- **Never enable Ubuntu's `nftables.service`.** Its stock `/etc/nftables.conf` begins with `flush ruleset`, which would
  delete every rule Docker has installed and break container networking until the daemon is restarted. The guard ships
  its own unit loading its own file for exactly this reason.

The guard covers bridge-networked containers, which is all of them by design. A container using `network_mode: host`
shares the host's stack, so its traffic is `output` and the guard does not apply — do not add one. Do not remove the
guard while resource access is in place, and do not grant resource access to a second host without it.

**G17 — Never bind-mount a single config file into a container that Ansible templates.** `ansible.builtin.template`
replaces files by atomic rename, which allocates a new inode; a single-file bind mount stays pinned to the old one, so
the container keeps reading the pre-edit content forever. Found in Phase 6: the Caddyfile flip from the staging CA
produced `changed` on the template task, the reload handler ran — and Caddy logged `config is unchanged`, because
inside the container the file had never changed. Mount a directory (renames inside a mounted directory are visible)
and keep the templated file in it.

**G18 — CIS's host-firewall chapter is incompatible with this host; `usg fix` must run tailored.** Found in Phase 8:
the stock `cis_level1_server` remediation (a) wrote an `/etc/nftables.conf` beginning with `flush ruleset`, then enabled
**and started** `nftables.service` — the flush deleted Docker's chains and the `personal_infra_guard` table (G16) the
moment it ran, and would have re-run on every boot; (b) purged `ufw`; and (c) appended `net.ipv4.ip_forward = 0` and
`net.ipv6.conf.all.forwarding = 0` to `/etc/sysctl.conf` and applied them, severing container NAT — inbound traffic
survived only because `docker-proxy` happens to listen on the published ports directly, while container-outbound
(Telegram API, Let's Encrypt renewals) went dark.

The hardening role therefore applies a **tailored** profile: `roles/hardening/files/cis-level1-server-tailoring.xml`
(generated with `usg generate-tailoring cis_level1_server`, consumed by `usg fix --tailoring-file`) deselects the whole
host-firewall chapter — ufw, nftables, iptables and iptables-persistent, CIS 4.2–4.4 — plus the two forwarding sysctls
in 3.3, 22 rules in all. The rationale is the architecture, not convenience: the network perimeter of this host is the
Lightsail firewall (G3, G11), and packet-level policy on the box belongs to Docker's managed chains and the metadata
guard (G16). A host-level default-deny firewall here would either duplicate the Lightsail rules or fight Docker's chain
management, and `iptables-persistent` would restore a stale snapshot of Docker's dynamic rules at boot. The `docker`
role additionally enforces `nftables.service` disabled and stopped, so even an untailored `usg fix` cannot leave the
boot-time flush armed. After a USG benchmark upgrade, regenerate the tailoring and re-apply the 22 deselections.
