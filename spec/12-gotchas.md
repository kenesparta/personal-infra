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

**G19 — `immutable` cannot be taken back, and CloudFront TTLs never reach the browser.** (rev 2.4) The CDN
distribution's min/default/max TTLs govern only CloudFront's edge cache; what a browser does comes from the
`Cache-Control` response header, and a CloudFront invalidation clears the edge, never a browser that already holds the
object. An object served once with `public, max-age=31536000, immutable` is pinned in that browser for up to a year
with no server-side undo. The CDN therefore carries two response-headers policies (spec §4): the year-long immutable
header is attached via ordered cache behaviors only to the filename-versioned, write-once paths `fonts/*` and
`blog/*`, while the default behavior sends `public, max-age=300` with override **off**, deferring to per-object
`Cache-Control` metadata — which is how the typst-resume CI keeps `cv/ken_esparta_cv.pdf`, a shared stable URL
overwritten in place, at one hour. Two sharp edges: response-headers policies apply to error responses too, so
requesting a not-yet-uploaded asset under an immutable path pins the 403 as well — upload assets *before* publishing
references to them; and per-object metadata is honoured only on the default behavior, because the immutable policy
overrides it.

**G20 — Weekly snapshots are *manual* snapshots, and manual snapshots never expire.** (rev 2.5) The AutoSnapshot
add-on is daily-only — neither its frequency nor its seven-copy retention is configurable — so the weekly Sunday
schedule is an EventBridge rule invoking a Lambda (§5.8) that calls `CreateInstanceSnapshot` and then prunes. What it
creates are ordinary manual snapshots: nothing in Lightsail ever deletes one, so the Lambda's prune — scoped to names
starting with `<instance>-weekly-` — is the only thing bounding their cost. Consequences: renaming the prefix orphans
every existing weekly snapshot, which then bills forever until deleted by hand; snapshots outside the prefix
(`pre-harden-*` and other hand-made ones) are deliberately never candidates; and a broken Lambda means snapshots stop
being *created*, not just pruned — there is no alarm at this scale, so check `aws lightsail get-instance-snapshots`
when in doubt. Note the add-on's own stored dailies do not linger under the weekly regime: any that remain after
disabling it are deleted by hand at cutover, so the restore points that persist are the weeklies and the hand-made
manual snapshots.

**G21 — The CloudWatch logs key is the host's only static AWS credential, and the `awslogs` driver has sharp edges.**
(rev 2.7) The driver runs inside dockerd, which cannot use the instance's metadata credentials — resource access covers
exactly one bucket (G5) — so AD-11 puts an IAM user's key on the box: Vault → `0600` root-only drop-in
`/etc/systemd/system/docker.service.d/awslogs-credentials.conf`. Containers cannot read the daemon's environment, so
G16's guard and threat model are untouched. Things that bite:

- **The writer cannot create log groups** — deliberately, because driver-created groups never expire. A container whose
  group is missing **fails to start**. Ordering on any change: `terraform apply` (groups) → vault → `make configure`,
  and never delete a `/kenesparta/*` group while a container references it.
- **A credential change needs daemon-reload plus a docker restart** — the shared `Restart docker` handler does both, and
  `live-restore` keeps containers up through it. But a daemon restart does not re-drive logging config: a container
  keeps the driver settings it was *created* with until it is **recreated** (the deploy role's `docker compose up -d`
  does that whenever the Compose file changes).
- **`mode: non-blocking` is load-bearing.** The driver's default blocking mode couples application stdout to CloudWatch
  availability — an unreachable endpoint stalls the app. Non-blocking drops lines when the 4 MB buffer fills instead;
  on this box, losing log lines beats losing the service.
- **`docker logs` still works** (dual-logging cache, Docker ≥ 20.10). Do not "fix" an apparent absence of local logs by
  re-adding a `json-file` block.
- **Rotation is one-sided**, unlike the origin secret (G13): mint a second key on the IAM user, splice Vault, run
  `make configure`, then delete the old key.

**G22 — A new project's image must exist in GHCR *before* its first `make configure`.** (rev 2.10) The `deploy` role's
last two steps are not just template writes: "Start each project" runs `docker_compose_v2` with `pull: missing`, which
is a real pull. Add an entry to `projects.yml` before CI has ever pushed its image and that task fails on the new
project, which fails the play — so the `backup` role never runs and the host is left half-configured, even though the
two projects that *were* already running keep serving (nothing tore them down). The same is true of a typo in `image:`,
and it looks identical.

The full ordering for adding a project is therefore three-sided, and only the first two are obvious:

1. `terraform apply` — creates `/kenesparta/<name>`. A container whose log group is missing fails to start (G21).
2. Vault — `vault_postgres_passwords.<name>` (site.yml refuses to run without it) plus any `vault_project_env.<name>`.
3. **`docker push` to GHCR** — at least one image under the moving tag.

...and only then `make configure`. Steps 1 and 2 fail loudly and early, in a pre-task or on container start; step 3
fails in the middle of a run that has already changed the host. If the image genuinely is not ready yet, leave the
project out of `projects.yml` rather than committing an entry that cannot converge — a half-applied `projects.yml` is
the one state neither tool is designed to sit in.

**G23 — A zone whose registrar is not Route 53 has a manual, ordered cutover, and DNSSEC makes the last step a
foot-gun.** (rev 2.12; **executed and closed for all three domains 2026-08-23** — see §5.6.1 for the published DS
records. The procedure below is retained because it applies verbatim to the next domain, and to any KSK rotation on
an existing one.) Unlike `kenesparta.dev` and `kecc.link`, this domain's registrar is not Route 53.
Terraform can create the hosted zone, sign it, and write records into it, and **none of that is visible to the
internet** until the nameservers are changed by hand in the Namecheap dashboard. Two things break if the steps are
run in the wrong order:

- **`terraform apply` hangs before the delegation.** `aws_acm_certificate_validation` polls until the validation CNAME
  resolves publicly. Before delegation it never will, so a full apply blocks for its 45-minute timeout and then fails
  — with the zone, the certificate request and the distribution already created, which is confusing but not harmful.
- **A DS record published before signing is live is an outage, and a resolver-cached one is a long outage.** Once the
  DS is at the registrar, validating resolvers *require* a good signature. Publish it while the zone is unsigned, or
  while the domain still answers from Namecheap's nameservers, and `auruming.com` becomes SERVFAIL — not "wrong
  answer", but *no* answer — for everyone behind a validating resolver, until the DS expires from their caches.

The order is therefore:

1. `make dns/auruming-zone` — create the zone only (a targeted apply; see G25 for why not bare `terraform`).
2. `make dns/auruming` — read the four nameservers.
3. **Namecheap → Domain → Nameservers → Custom DNS** — paste the four. Wait for `dig NS auruming.com` to return them
   (registry TTL, typically minutes to a few hours).
4. `make plan && make apply` — the certificate now validates, and the rest of the estate applies normally.
5. `make dns/auruming` again — read the DS record, now that signing is active.
6. **Namecheap → Domain → Advanced DNS → DNSSEC** — add the DS. Verify with
   `dig +dnssec auruming.com` (expect `ad` in the flags from a validating resolver) or
   `https://dnsviz.net/d/auruming.com/dnssec/`.

Step 6 is the only one that is genuinely dangerous, and it is the only one that can be undone slowly rather than
quickly: removing a DS record propagates on the registry's TTL, not yours. Do it last, and only after step 4 has
applied and `aws_route53_hosted_zone_dnssec.auruming` reports `SIGNING`.

Reversing the whole thing is step 3 in reverse (point the nameservers back), but **only after** the DS is removed and
has expired — a domain delegated away from a signed zone while its DS is still published fails validation exactly as
in step 6.

*As executed, 2026-08-23.* The delegation and DS landed without incident on all three zones, and the estate went from
signed-but-unenforced to validated. Two observations worth keeping:

- **A resolver can lag by a cache entry, and it looks like a failure.** Immediately after publication `auruming.com`
  validated on Google and Quad9 but not Cloudflare, which still held the apex answer cached from before the DS
  existed — and a cached-insecure entry keeps that status until it expires. The way to tell that apart from a broken
  chain is to query a name that cannot be cached: a random non-existent subdomain returned `ad` from the same
  resolver, which requires walking root → parent → zone to prove the NXDOMAIN. Confirm the resolver validates at all
  with `dig dnssec-failed.org @<resolver>` — that must be SERVFAIL.
- **The mail records are the reason to sequence this.** `kenesparta.dev` carries the Proton MX/SPF/DKIM/DMARC set, so
  its blast radius on a bad DS is inbound mail, not just the websites. Do the lowest-stakes domain first, confirm
  `ad`, and leave that one for last.

**G24 — `local.domains` is the only thing stopping a project's records landing in the wrong zone.** (rev 2.12) Before
AD-13 there was one zone and one certificate, and `local.zone_id` was correct by construction. Now `domain` in
`projects.yml` chooses both, and the two failure shapes are asymmetric:

- **A `domain` naming no key in `local.domains`** fails the plan on the map lookup. Loud, early, free.
- **A `domain` naming the *wrong* known key** succeeds completely: the records are created, the certificate is
  attached, the plan is clean — and the hostname resolves in a zone that is not authoritative for it, so it does not
  resolve at all. Nothing in Terraform can catch this, because `hostname: auruming.com` under `domain:
  kenesparta.dev` is a perfectly well-formed request to create a record named `auruming.com` inside the
  `kenesparta.dev` zone, which Route 53 will happily do.

So: `hostname` and `origin` must both be within `domain`, this is not machine-checked, and the symptom is NXDOMAIN
rather than an error. When adding a project, read the three fields together as one line.

Do **not** try to derive the zone from the hostname instead (longest-suffix match over `local.domains`). It looks
like it removes the field, but it silently changes meaning the day two managed domains are suffixes of one another,
and it turns a typo in `hostname` into a record in a different domain's zone — trading an explicit field for an
implicit rule with a worse failure mode.

**G25 — Bare `terraform` picks up the wrong credentials and fails as if SSO had expired.** (rev 2.12) Every Terraform
operation in this repository goes through `make`, and that is not a style preference. The Makefile does
`-include terraform/.env`, which exports `TF_VAR_aws_sso_profile`; `versions.tf` then sets
`profile = var.aws_sso_profile != "" ? var.aws_sso_profile : null`. Run `terraform -chdir=terraform …` directly and
that variable is `""`, so the provider gets `profile = null` and the AWS SDK falls through its default chain — which
on this machine finds a **`[default]` profile in `~/.aws/credentials`** holding long-dead static keys.

The error is actively misleading:

```
Error: Retrieving AWS account details: validating provider credentials:
retrieving caller identity from STS: … api error InvalidClientTokenId:
The security token included in the request is invalid.
```

That reads like an expired SSO session, and the reflex is to run `make login` — which changes nothing, because the
SSO session was never the problem and is very likely still valid. Confirm with
`aws sts get-caller-identity --profile "$TF_VAR_aws_sso_profile"`: if that succeeds while `terraform` fails, the
profile is not reaching the provider and the fix is to invoke it through `make`.

`null` rather than `""` is deliberate in `versions.tf` — an empty string makes `terraform init` fail outright, and CI
needs the fall-through so its OIDC env credentials are used. The cost of that flexibility is precisely this failure
mode locally.

So: **no target in this repository should document a bare `terraform` command.** A one-off operation that needs
`-target` gets a Makefile target of its own (`dns/auruming-zone`), which is also where the justification for
`-target` belongs — Terraform prints a "resource targeting is in effect" warning on every such run, and a warning
with no written reason next to it is one people learn to scroll past.

**G26 — Docker is deliberately excluded from every automatic security update, and nothing says so out loud.** (rev
2.16) `/etc/apt/apt.conf.d/52personal-infra` (the `common` role) blacklists `docker-ce`, `docker-ce-cli` and
`containerd.io`. The reason is sound: an unattended `docker-ce` upgrade restarts the daemon, and with four services on
one host that is every container down mid-request, at 06:00, unwatched. But the consequence is a standing blind spot —
the one component reachable from the internet on ports 80 and 443 by way of Caddy is also the one component
`unattended-upgrades` will never patch, and its log will not mention the packages it was told to skip.

`make security/check` surfaces the held-back versions for exactly this reason. Upgrading them is a manual, scheduled
act, in a window where someone is watching:

```bash
ssh ubuntu@HOST sudo apt-get install --only-upgrade docker-ce docker-ce-cli containerd.io
ssh ubuntu@HOST docker compose -f /opt/personal-infra/caddy/docker-compose.yml ps   # …and each project
```

Two traps in that upgrade. `live-restore` (set by the `docker` role) keeps containers running across a daemon restart
but **not** across a containerd restart, so expect the containers to bounce anyway — plan for it rather than being
surprised by it. And the same blacklist is why `make security/apply` cannot be a synonym for `apt upgrade`: the
playbook drives `unattended-upgrade`, the very binary the nightly timer runs, so it inherits this policy instead of
re-stating it. Re-stating it is how the two paths would eventually disagree, and the disagreement would only ever be
noticed as an outage (spec §9.7).

**G27 — `/var/run/reboot-required` is not a reliable answer to "does this host need rebooting?"** (rev 2.17) Found on
2026-09-01, by the check that had just been written to trust it: the host was running `7.0.0-1009-aws` with
`7.0.0-1011-aws` installed and `linux-image-aws` pointing at it, and the flag file did not exist — so
`make security/check` reported *no reboot required* while two kernel revisions of security fixes sat on disk, unbooted,
after 31 days of uptime.

The flag is written by an `update-notifier` package hook, and it lives in `/var/run`, a **tmpfs**. It is therefore a
statement about "did a hook fire since the last boot", not about "is the running kernel the newest installed one".
Anything that installs a kernel without that hook — and anything that clears the tmpfs — leaves the file absent on a
host that genuinely needs a reboot. Absence proves nothing; presence is still meaningful.

`needrestart -b -r l` answers the real question, because it *compares* rather than remembers:

```
NEEDRESTART-KCUR: 7.0.0-1009-aws     # running
NEEDRESTART-KEXP: 7.0.0-1011-aws     # newest installed
NEEDRESTART-KSTA: 3                  # 1 current, 2 ABI-compatible pending, 3 version upgrade pending
NEEDRESTART-SVC: docker.service      # …one line per service still mapping deleted libraries
```

`security.yml` reads both and treats **either** as reason to report a reboot due. Two details matter when touching it.
`-r l` forces list-only: needrestart's restart mode is otherwise interactive or automatic depending on context, and
that task also runs on the read-only `make security/check`. And `KSTA` must be compared **as a string** —
`set_fact` puts a bare `"3"` through `literal_eval` and hands back the integer `3`, so `in ['2', '3']` is silently
False without a `| string`. The symptom of getting that wrong is identical to the bug this gotcha is about: a clean
report on a host that needs rebooting.

Same shape as the DNSSEC check in acceptance criterion 11 — the obvious probe returns a reassuring answer to a
question you did not ask.

**G28 — `response_page_path` is a path *inside the same distribution*, so a custom error page served from the broken
origin is no page at all.** (rev 2.18) The obvious way to write a maintenance page is one `custom_error_response`
block naming `/maintenance.html`. It applies cleanly, and it does nothing: `response_page_path` is not a URL, it is a
URI that CloudFront re-resolves through *its own* cache behaviors. With only the Caddy origin configured, CloudFront
answers a 504 by fetching `/maintenance.html` from the origin that just failed to answer, fails again, and falls back
to the generic AWS page — the exact page the change was meant to remove. The failure is silent in the worst way: the
Terraform plan is clean, the apply succeeds, and the setup is only exercised during an outage, when nobody is reading
CloudFront configuration.

The page must therefore come from a **second origin that is up when the first is down** — S3 behind OAC, plus an
`ordered_cache_behavior` whose `path_pattern` matches the error path and targets it (§5.15). Three consequences:

- **The path pattern and the page path must agree.** `path_pattern = "/__status/*"` with
  `response_page_path = "/maintenance.html"` routes the error page to the *default* behavior — the origin again. This
  is the same bug wearing a disguise.
- **Everything the page references is subject to the same rule.** A stylesheet, a font, a logo at any path not
  covered by the status behavior is fetched from the dead origin. Inline all of it; the pages in
  `terraform/status-pages/` carry no external reference of any kind.
- **Test it by breaking the origin, not by reading the plan.** `docker compose stop caddy` on the host produces a real
  502/504 through the real path. Nothing short of that exercises it.

The same trap explains why the legal site's 403/404 → `/404.html` (§5.11) is *not* an instance of it: that
distribution's only origin is S3, so the error page and the content share an origin that does not go down.

**G29 — A Caddy error page served with `file_server` returns 200, which silently switches off the CloudFront layer
above it.** (rev 2.19) `handle_errors` runs a fresh route, and whatever that route writes decides the status.
`file_server` writes **200**. So the natural-looking block —

```
handle_errors 5xx {
    root * /srv/errors
    rewrite * /blog.html
    file_server           # ← no status override
}
```

— turns a 502 from a dead container into a *successful* response whose body happens to say the site is down. Three
things break at once, none of them loudly: CloudFront's `custom_error_response` never fires because there is no error
to map (§5.15), the edge caches a 200 as a normal page, and a crawler indexes the maintenance text as the site's real
content. Every layer behaves correctly on the input it was given; the input was wrong.

The fix is one subdirective, and it is load-bearing rather than cosmetic:

```
    file_server {
        status {err.status_code}
    }
```

Verify by status code, never by eyeball — the page looks identical either way, which is exactly why this survives a
visual check. Reach Caddy directly, past the edge, with the gate's own header:

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "X-Origin-Verify: $SECRET" https://origin-bot.kenesparta.dev/
```

502 is right; 200 means the whole chain above is now decorative.

**G30 — A cache policy with the accept-encoding flags off never forwards `Accept-Encoding`, and Caddy then fakes
one.** (rev 2.21) `enable_accept_encoding_gzip` and `enable_accept_encoding_brotli` read like cache-key tuning — flags
to leave off on a policy that caches nothing, which is how `CachingDisabled` ships and how §5.10 first copied it. They
are also the only thing that puts the viewer's `Accept-Encoding` into the origin request: with both off, CloudFront
drops the header, and the all-except-Host ORP does not bring it back. From there, three layers each behave correctly
and the viewer still gets nothing compressed:

- **Caddy asks for gzip on its own.** `reverse_proxy` uses Go's HTTP transport, which adds `Accept-Encoding: gzip` to
  any upstream request that has none and then *transparently inflates* the answer. So the application does compress,
  on every request, and Caddy undoes it before the response leaves the box.
- **The inflated response has no `Content-Length`.** Go forwards it chunked.
- **So the edge cannot compress it either.** `compress = true` on the behavior needs the flags on *and* a
  `Content-Length`, and here it had neither.

The symptom is a response with `vary: accept-encoding` — proof the application considered compressing — and no
`content-encoding`. The one uncompressible response nearby (a `favicon.ico`, which the application never tries to
compress) keeps its `content-length` while every compressible one has lost it; that asymmetry is the tell that the
inflation happened in Caddy, not in the app. Reproduced 2026-09-17 with `caddy:2-alpine` in front of the
`auruming.com` binary: `request_header -Accept-Encoding` before `reverse_proxy` turns a 2.7 KB brotli stylesheet into
10.8 KB of identity, chunked.

The fix is the two flags, on the shared `disabled_plus_geo` policy (§5.10 amended). Verify through the edge, not the
plan — the plan is a two-attribute in-place update and says nothing about bytes:

```bash
curl -s -o /dev/null -D - -H 'Accept-Encoding: br, gzip' https://auruming.com/ | grep -i '^content-encoding'
```

`content-encoding: br` is right. Nothing at all means the header is still not reaching the origin.

**G31 — `hashed_assets` pointed at reused file names caches one build for everyone, and only an invalidation clears
it.** (rev 2.22) The field takes a path pattern, and the policy behind it honors the origin's `Cache-Control` up to a
year (§5.16). Aimed at files whose names change with their contents, staleness is impossible by construction: a new
build is a new URL and the old entries simply age out unread. Aimed at a path that reuses names, it is one deploy
away — the edge keeps the previous bytes under the same URL and serves them to every viewer who never had them,
which is worse than the browser cache it resembles, because no viewer can clear it.

`kenesparta.dev` is the project this is about. It serves `/pkg/kenespartadev.css`, one name for every build, and it
is a Leptos app like `auruming.com` — the `/pkg/` path, the image shape and the `projects.yml` entry all look the
same. Today it sends no `Cache-Control` at all, so even with the field set nothing would be cached
(`default_ttl = 0`); the trap is a reasonable `max-age` added to that app later by someone who has never read this
file, with the field already in place and nothing to warn them.

So the question before adding the field is not "does it serve `/pkg/`" but **"does the name change when the bytes
do"** — for a Leptos app, `LEPTOS_HASH_FILES=true` in the image, with `hash.txt` beside the binary. Undoing a mistake
is per distribution and not in Terraform:

```bash
aws cloudfront create-invalidation --distribution-id <id> --paths '/pkg/*' --profile "$TF_VAR_aws_sso_profile"
```
