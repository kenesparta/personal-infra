# 3. Architecture Decisions

Each decision records what was chosen, why, and what was explicitly rejected. Do not re-litigate during implementation.

## AD-1 — Lightsail instance over EC2 and over Lightsail Containers

**Chosen:** Lightsail **Small** bundle `small_3_0` — 2 vCPU, 2 GB RAM, 60 GB SSD, 3 TB transfer, dual-stack, $12/mo —
Ubuntu 24.04.

**Rationale:** EC2 at equivalent spec costs more once storage, IPv4, and egress are unbundled. The current Container
Service (`nano`, 0.25 vCPU / 512 MB) is cheaper still but hosts exactly one container, cannot run Postgres, and gives
no shell. At $12 the whole estate lands *below* today's bill ([§14](14-cost.md)) while gaining a shell and room for more than one
service.

**RAM is the binding constraint, not CPU or disk.** Indicative budget at 2 GB:

| Component                          | Resident |
|------------------------------------|----------|
| OS + Docker daemon                 | ~350 MB  |
| PostgreSQL (tuned, see below)      | ~400 MB  |
| Caddy                              | ~50 MB   |
| Each Rust service (Leptos SSR)     | ~100 MB  |

At C3's ceiling of **four services** that totals ~1.2 GB, leaving ~800 MB for page cache and burst — a real margin
rather than a squeeze. This is why C3 is four and not more: four fits `small_3_0` with headroom, and each additional
service costs ~100 MB against a fixed 2 GB. The `projects.yml` fan-out means growing past four is a bundle change, not
a redesign.

The ~100 MB per-service figure assumes a release-mode Leptos SSR binary. A service that holds large caches or does
image processing will not fit that budget — measure before adding the fourth.

Postgres must be tuned down from Ubuntu's defaults for this to hold: `shared_buffers = 256MB`,
`effective_cache_size = 768MB`, `max_connections = 40`, `work_mem` small. The `postgres` role owns these; leaving
defaults on a 2 GB box invites the OOM killer.

**Trigger to resize:** sustained memory pressure (swap in use, or a container OOM-killed). `medium_3_0` ($24, 4 GB) is a
stop/change-bundle/start operation on a snapshot — minutes of downtime, no redesign, no data movement if the snapshot
is current.

**Rejected:** EC2 (revisit only if custom AMI pipelines become necessary); staying on Lightsail Containers (does not
meet C3); `medium_3_0` up front (pays $12/mo for capacity that is not yet needed — the trigger above buys it when it
is).

## AD-2 — No load balancer

**Chosen:** Caddy on the instance, ports 80/443 published directly.

**Rationale:** An ALB costs ~$16–22/mo before traffic and provides no availability benefit in front of a single
instance.

**Rejected:** ALB, NLB, and a dedicated reverse-proxy VM. The latter adds cost, a network hop, and a second point of
failure without removing the first.

*Amended in rev 2:* this decision rejects a **load balancer**, not the CDN. CloudFront is retained — see AD-8.

## AD-3 — Self-hosted PostgreSQL, one instance, one database per project

**Chosen:** **One** Postgres instance for the whole host, one `DATABASE` and one role per project. It runs as a single
container on the shared `web` network, reachable only as `postgres:5432` from other containers, publishing **no** port
to the host.

**Rationale:** Four Postgres *instances* would each carry independent `shared_buffers`, WAL, and autovacuum overhead —
roughly 4× the fixed cost for the same data, which a 2 GB host cannot absorb (AD-1). One instance means one backup job
and one upgrade path. Replaces the current Lightsail managed database, saving ~$15/mo.

*Amended in rev 2.1 — containerized rather than apt-installed on the host.* The original wording said "one Postgres
process on the host … bound to `127.0.0.1`", which cannot be reconciled with the rest of the design: applications are
containers on a bridge network (AD-8, §9.3's `reverse_proxy blog:3000`), and `127.0.0.1` inside such a container is its
own network namespace, not the host's. The three ways to close that gap were:

- **Containerize Postgres on `web`** *(chosen)* — applications resolve `postgres:5432` by Docker DNS. Nothing listens on
  a host interface at all, so the exposure property AC-8 was protecting is strengthened rather than weakened, and there
  is no host-vs-daemon start-ordering hazard.
- *Host install listening on the bridge gateway* — keeps the apt install, but `listen_addresses` must then name a
  Docker-owned IP. If `postgresql.service` wins the boot race against `docker.service` the address does not exist yet
  and Postgres **fails to start**, so it needs a systemd ordering drop-in coupling the database to the container
  runtime. Rejected as the more fragile of the two.
- *Host install plus a unix-socket bind-mount* — strictly satisfies the original `127.0.0.1`-only wording, but `/run` is
  a tmpfs: on reboot Docker can create an empty root-owned `/run/postgresql` before Postgres starts, which then
  prevents Postgres from creating its socket. A start-order deadlock for no security gain. Rejected.

**Consequences.** The `postgres` role manages a Compose stack instead of an apt package; tuning is passed as `-c` flags
(§9.5); databases, roles and backups are driven through `docker exec`; and the data directory is a named Docker volume,
which — like Caddy's `/data` (G8) — is load-bearing and must survive container recreation.

**Rejected:** Lightsail managed database (the value is automated backups, replaceable by a `pg_dump` cron for ~$1);
Supabase and equivalent BaaS, per user constraint; one Postgres container *per project* (the 4× overhead above).

**Migration note:** the production write path is the `ingest` CLI only — the web app never writes. Postgres is therefore
effectively read-only in production, so the dump/restore carries no concurrent-write hazard.

## AD-4 — Caddy over Traefik/nginx

**Chosen:** Caddy 2, templated Caddyfile, **stock image — no plugins**.

**Rationale:** Automatic ACME issuance and renewal with no plugin. Static config is easier to debug under failure.

**Consequence for rev 2:** "no plugins" rules out the Route 53 DNS-01 provider, which forces the origin-hostname design
in AD-8. Every hostname Caddy holds a certificate for must resolve **directly to the instance** so HTTP-01 can succeed.

## AD-5 — Pull-based deployment

**Chosen:** CI pushes images to GHCR; the instance polls via a systemd timer running
`docker compose pull && docker compose up -d`.

**Rationale:** Requires zero inbound connectivity for deploys. Push-based SSH from GitHub-hosted runners would require
opening port 22 to GitHub's broad, rotating IP ranges.

**Consequence for rev 2:** CI no longer performs a `terraform apply`. The GitHub OIDC role sheds its ECR-push,
Lightsail-deploy, and Terraform-state policies, retaining only the `cdn.kenesparta.dev` S3 write used by the
`typst-resume` repository.

**Rejected:** SSH-based deploy actions, self-hosted runners.

## AD-6 — Terraform manages infrastructure only

**Chosen:** Terraform provisions the instance, IP, firewall, DNS, certificates, CDN, and backup bucket. It does **not**
manage application deployment, Caddyfile contents, database schemas, or container lifecycle.

**Rationale:** Those change on a different cadence and belong to the deploy pipeline. Mixing them causes Terraform to
fight the running system.

## AD-7 — Ansible for configuration management

**Chosen:** Ansible owns everything between "instance exists" and "applications can be deployed."

**Rationale:** Gotcha G4 is the forcing function. `user_data` is `ForceNew` on `aws_lightsail_instance`, so every config
change routed through Terraform destroys and recreates the host. That leaves three options: keep config in a long
`user_data` script and accept replacement on every edit; do it manually and lose reproducibility; or hand mutable host
state to a config-management tool. Only the third is viable.

Ansible specifically because it is **agentless** — it runs over the SSH connection that already exists, consistent with
the decision to keep no daemons on the box (AD-5). It also gives the spec a secrets story: Postgres passwords, the GHCR
token, and the CloudFront origin secret live in Ansible Vault rather than in Terraform state.

**Consequence:** `bootstrap.sh` shrinks to the minimum needed to accept an Ansible connection. Everything else moves
into roles. G4's blast radius drops from "any config change" to "almost never."

**Rejected:** cloud-init alone (same ForceNew problem); shell scripts over SSH (no idempotency, no dry-run);
Chef/Puppet/Salt (require an agent or a server).

## AD-8 — CloudFront is retained; one distribution and one origin hostname per project

**Chosen:** Each project gets its own CloudFront distribution and its own `origin-<project>.kenesparta.dev` A record
pointing at the static IP. Public hostname → CloudFront (ACM cert) → origin hostname → Caddy (Let's Encrypt cert) →
container.

**Rationale:** three facts collide and only this shape satisfies all of them.

1. **ACM certificates cannot be installed on a Lightsail instance.** Standard ACM public certs are non-exportable, so
   the box can never serve the ACM cert directly. Lightsail's own certificate service has the same restriction — it
   attaches to load balancers, container services, and CDN distributions, never to an instance. The host therefore needs
   Let's Encrypt regardless of what sits in front of it.
2. **CloudFront routes by path pattern, not by Host.** One distribution with four aliases sends all four to the same
   origin under the same behavior, so a single distribution cannot fan out to four backends.
3. **A hostname that resolves to CloudFront cannot satisfy an HTTP-01 challenge on the instance** — the challenge
   request lands at the CDN. Caddy can therefore only obtain certificates for names that point straight at the box, and
   AD-4 forbids the DNS-01 plugin that would lift that restriction.

Per-project distributions cost nothing extra: CloudFront bills for requests and transfer, not per distribution.

**Origin lockdown:** Lightsail instance firewalls accept plain CIDR lists and **cannot** reference the
`com.amazonaws.global.cloudfront.origin-facing` managed prefix list, and CloudFront's origin ranges rotate. The origin
is therefore protected by a shared secret instead: each distribution injects `X-Origin-Verify: <secret>` via
`custom_header`, and Caddy returns 403 to any request lacking it. The secret lives in Ansible Vault and in Terraform
state; rotating it is a two-sided change.

**Rejected:**
- *Single distribution forwarding the viewer Host* — requires Caddy to hold certs for names pointing at CloudFront,
  i.e. DNS-01, i.e. a custom Caddy build (violates AD-4).
- *Single distribution, HTTP-only origin* — removes the cert problem but sends all origin traffic in plaintext across
  the public internet, protected only by the shared secret.
- *Lightsail CDN distribution* — takes the instance as origin directly and is cheaper, but is far less configurable and
  would retire the existing ACM cert for the apex.
- *No CDN at all* (rev 1's C4) — simplest and free, but discards the working CloudFront estate and publishes the origin
  IP.

## AD-9 — State consolidation by copying the state object, not by import blocks

**Chosen:** copy `s3://tf.kenesparta.dev/dns/prod/kenesparta.dev` to the new key, then evolve the configuration in
place: keep the `.tf` files for resources that survive (under identical resource addresses), add the new instance
resources, and remove the container-service and ECR resources.

**Rationale:** the old state already contains every resource that is moving. Copying it preserves ~25 resources with
zero import statements and zero risk of an address typo silently orphaning a resource. Resource addresses are preserved
verbatim (`aws_route53_zone.kenespartadev`, `aws_kms_key.kenespartadev_key_dnssec`, …), so Terraform sees no diff for
anything that is not deliberately changing.

The old state object is left in place untouched as a rollback point.

**Rejected:** `import {}` blocks for every resource (~25 hand-written IDs, several of which — DNSSEC key-signing keys,
CloudFront OAC, ACM validation records — have non-obvious ID formats); `terraform state mv` across backends (no
cross-backend support).

**Absolutely forbidden:** running `terraform destroy` in `kenesparta.dev/tf`. See G10.

## AD-10 — GHCR over ECR

**Chosen:** images published to `ghcr.io/kenesparta/<project>`; the instance authenticates with a GHCR PAT held in
Ansible Vault.

**Rationale:** a Lightsail instance **cannot assume an IAM role** (G5). Pulling from ECR from the box would require a
long-lived IAM access key on disk *plus* a second systemd timer re-running `aws ecr get-login-password` before the
12-hour token expires. A GHCR PAT is one credential with no refresh machinery. CI authenticates to GHCR with the
built-in `GITHUB_TOKEN`, removing AWS from the build job entirely.

**Consequence:** the ECR repository, its lifecycle policy, its Lightsail pull policy, and the CI role's ECR policy are
all destroyed.

## AD-11 — Container logs ship to CloudWatch Logs via the `awslogs` driver (rev 2.7)

**Chosen:** each project container's stdout/stderr goes to a CloudWatch Logs group `/kenesparta/<name>` —
Terraform-managed, **7-day retention** — through Docker's native `awslogs` driver, configured per service in the deploy
role's Compose template (`mode: non-blocking`). The daemon authenticates with a dedicated IAM user
(`<instance>-logs-writer`) allowed exactly `logs:CreateLogStream` and `logs:PutLogEvents` on those groups; its access
key is minted **out of band**, lives in Ansible Vault, and reaches dockerd as a root-only systemd drop-in (§5.9, G21).
Caddy and Postgres stay on the local `json-file` daemon default.

**Rationale:** the driver already lives in the daemon — no agent, no sidecar, nothing new resident against AD-1's RAM
budget — and logs become durable off-host, tailable and queryable (`aws logs tail`, Logs Insights). Seven days is a
debugging window, not an archive; at this traffic the cost is cents (§14).

The forcing constraint is credentials. The driver runs *inside dockerd*, and the instance's only native credentials —
bucket resource access (G5) — cover exactly one Lightsail bucket and nothing else. CloudWatch therefore costs this
design its first **static** AWS credential on the host. Accepted because the blast radius is writing noise into
`/kenesparta/*` log streams: the key can create no groups, read nothing, and touch nothing else, and it sits where
containers cannot reach it (the daemon's environment, not metadata — G16 is unchanged). Like the bucket key that was
never created, it is minted out of band because `aws_iam_access_key` would put the secret half in state (G5).

**Rejected:**

- *The CloudWatch agent, fluent-bit, or vector* — each is a resident process against a 2 GB budget (AD-1), doing what
  the daemon does natively.
- *Instance metadata credentials* — bucket-scoped only (G5); every CloudWatch call is `AccessDenied`.
- *Host-level shipping to the backup bucket* — the zero-credential alternative (host processes are deliberately outside
  the metadata guard's scope). Produces an archive, not a queryable/tailable service; revisit if the static key ever
  becomes unacceptable.
- *`awslogs-create-group: true`* — needs `logs:CreateLogGroup` and mints never-expiring groups; retention belongs to
  Terraform (G21).
- *Blocking mode (the driver default)* — couples application stdout to CloudWatch availability; an outage there must
  drop log lines, not stall the app (G21).

## AD-12 — Viewer IP and geolocation reach the applications as edge-injected headers (rev 2.8, amended 2.9)

**Chosen:** the applications log who reads what — viewer IP plus country/region/city — as fields in their own
CloudWatch-bound JSON events (AD-11). Both facts exist only at the edge, so the edge delivers them as headers, through
two mechanisms attached to **every** distribution:

- a viewer-request **CloudFront Function** (`kenesparta-true-client-ip`, AWS's documented
  add-true-client-ip-header pattern) that sets `true-client-ip` from `event.viewer.ip`. Assigning unconditionally
  makes it spoof-proof — a client-sent value never survives — and because the function edits the *viewer* request,
  the untouched `Managed-AllViewerExceptHostHeader` origin request policy forwards it like any other viewer header.
- a **custom cache policy** (`kenesparta-caching-disabled-plus-geo`) that keeps near-`Managed-CachingDisabled`
  semantics (`min_ttl = 0`, `default_ttl = 0`, `max_ttl = 1`, no accept-encoding normalization) and whitelists
  `CloudFront-Viewer-Country`, `CloudFront-Viewer-Country-Region-Name` and `CloudFront-Viewer-City` — cache-key
  values are automatically included in origin requests, which is the only way to carry CloudFront-generated headers
  without touching the ORP. `max_ttl` is 1, not 0, because `CreateCachePolicy` rejects any header whitelist once all
  three TTLs are 0 (`InvalidArgument`, hit on first apply 2026-08-01 — the §5.10 fallback, now enacted; rev 2.9).
  Nothing is cached unless the origin volunteers a `Cache-Control`, and then for at most one second. Because caching
  is now formally enabled rather than disabled, `Authorization` and all query strings ride the cache key too:
  in-key, `Authorization` is guaranteed into origin requests regardless of CloudFront's special GET/HEAD handling of
  that header, and any one-second cache entry is keyed on the exact request (path + query + token + geo), so entries
  can never collide across queries or bearers.

Caddy needs no change (`reverse_proxy` passes unrecognized request headers through), and apps that ignore the headers
are unaffected. Cost: zero — CloudFront Functions are inside the 2M/month always-free tier at this traffic, and cache
policies are free.

**Rationale:** the constraint is the Host header. Caddy routes projects by their `origin-*` vhost (AD-8), so the ORP
must keep excluding the viewer's `Host` — and no ORP header behavior combines "all viewer headers except Host" with
CloudFront-generated headers. Splitting the concern (IP via function, geo via cache policy) is the only shape that
leaves both the ORP and Caddy untouched. `CloudFront-Viewer-Address`/`-ASN` are rejected in cache policies, which is
why the IP needs the function at all.

**Rejected:**

- *Swapping the ORP to `allViewerAndWhitelistCloudFront`* — forwards the viewer's `Host` (`kenesparta.dev`), which no
  Caddy vhost matches; every request through every distribution breaks at once (AD-8).
- *A `whitelist` ORP naming viewer + CloudFront headers* — anything unlisted is dropped; enumerating what SSR and
  server-function POSTs need (`Content-Type`, `Accept`, cookies, …) fails silently the day a new header matters.
- *Deriving the IP from `X-Forwarded-For`* — Caddy only honors XFF from `trusted_proxies`, which would mean
  maintaining CloudFront's ever-changing IP ranges on the host — the same moving allowlist already rejected at the
  firewall (G11) — and the leading XFF entries are client-controlled anyway.
- *GeoIP lookup inside the applications* (MaxMind) — a licensed database shipped into distroless images and kept
  fresh, plus resident memory against AD-1, to recompute what the edge already knows.
- *CloudFront standard or real-time logs* — a second, disjoint pipeline (S3 or Kinesis, plus delivery cost) whose
  rows cannot be joined with the applications' own events; the point of AD-11 is one queryable stream per project.
- *Carrying geo through the function too* (copy `cloudfront-viewer-*` out of the viewer-request event, keep the
  managed `CachingDisabled` policy) — the geo headers are only documented to appear in a function's event when a
  cache policy or ORP references them, which is the same circularity, and a silent-absence failure mode if the
  `allExcept` ORP doesn't count as "all viewer headers". Only `event.viewer.ip` is unconditionally present, which is
  why the function carries the IP and nothing else (rev 2.9).
