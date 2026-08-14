# 5. Resource Specification

## 5.1 Providers

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws  = { source = "hashicorp/aws", version = "~> 6.0" }
    sops = { source = "carlpett/sops", version = "~> 1.2" }
  }
}
```

Region is `us-east-1` throughout. Rev 1 specified a second `aws.dns` provider alias for Lightsail DNS zones; that alias
is **removed** — Route 53 is global and the account already operates in `us-east-1`.

## 5.2 State backend

```hcl
terraform {
  backend "s3" {
    bucket       = "tf.kenesparta.dev"
    key          = "infra/prod/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true   # native S3 locking; no DynamoDB table required
  }
}
```

The bucket already exists. The state object is seeded by copying the old one (AD-9); the old key
`dns/prod/kenesparta.dev` is retained as a rollback point and never deleted by Terraform.

## 5.3 Project definition — single source of truth

`projects.yml` at the repository root is read by **both** tools: Terraform via `yamldecode(file("../projects.yml"))`,
Ansible via `vars_files`. It drives origin DNS records, CloudFront distributions, Caddy vhosts, Postgres databases, and
deploy timers. Adding a project is a five-line change in one file.

```yaml
projects:
  - name: blog
    hostname: kenesparta.dev          # public name (CloudFront alias)
    origin: origin.kenesparta.dev     # A record → static IP, Caddy vhost + LE cert
    image: ghcr.io/kenesparta/kenespartadev
    port: 3000
    database: blog
    env:                              # optional: non-secret container env, verbatim
      LEPTOS_SITE_ADDR: "0.0.0.0:3000"
      RUST_LOG: info
```

Two optional fields extend an entry (added in rev 2.3, for `budget`):

- `env` — a map of **non-secret** environment variables written verbatim into the project's `.env`. Secret values
  belong in `vault_project_env.<name>` (spec §9.4), which the deploy role merges in; nothing secret goes in this file.
- `origin_gate_env` — the name of an env var to fill with `vault_origin_secret`, for applications that verify the
  `X-Origin-Verify` header themselves in addition to Caddy's gate (the budget API's `ORIGIN_SECRET`). One source,
  no second copy to rotate (G13).

Each **non-blog** project that declares a `hostname` gets its own CloudFront distribution and alias records generated
from this file (blog keeps the migrated singleton distribution in `cloudfront.tf`). All of them ride the wildcard ACM
certificate — `hostname` must stay within `*.kenesparta.dev` (or the apex).

*Amended in rev 2.6:* the `budget` project is the **authenticated JSON API** (`api.kenesparta.dev`) backing the iOS
budget app; through rev 2.5 it was the private Telegram bot at `bot.kenesparta.dev`. The hostname swap is only a
CloudFront alias + Route 53 change — the distribution already forwards `Authorization` (AllViewerExceptHostHeader)
with caching disabled, so no behavior change was needed. Its `origin` stays `origin-bot.kenesparta.dev` **on
purpose**: the origin name is invisible to users, and renaming it would force a new Caddy vhost and a new Let's
Encrypt certificate against the shared rate budget (G8). App-side auth is per-user bearer tokens hashed in the
app's own database; the only vault change was swapping the Telegram secrets in `vault_project_env.budget` for
`CREDENCIALES_API` (§9.4 shape is unchanged).

*Amended in rev 2.10 — headless projects:* `hostname`, `origin` and `port` are optional, but only **as a set**. A
project that omits all three is **headless**: it accepts no inbound connection, and therefore gets no CloudFront
distribution, no `hostname` alias records, no origin `A` record, no Caddy vhost and no Let's Encrypt certificate.
Everything else is unchanged — GHCR image, deploy timer, Postgres role and database, the nightly dump, and the
`/kenesparta/<name>` CloudWatch group (§5.9).

```yaml
- name: cnayp_discord_bot
  image: ghcr.io/kenesparta/cnayp-discord-bot
  database: cnayp_discord_bot        # no hostname / origin / port — nothing connects to it
  env:
    RUST_LOG: info
```

The first such project is a Discord **gateway** bot: it dials out over WSS to Discord and holds that socket open for
its lifetime, and Discord delivers slash commands back down the same socket, so no part of the AD-8 edge chain has
anything to front. The alternative shape — registering an HTTP interactions endpoint URL with Discord — was rejected
for this service: it would buy a `hostname`, a distribution, a vhost and a certificate against the G8 budget purely to
receive events the gateway already delivers, and it would put a 3-second Discord response deadline behind a CloudFront
hop.

The three fields are optional **together and never individually**, and §9 asserts exactly that (all three, or none)
rather than defaulting the missing ones. The failure that assert exists to prevent is silent: an entry that lost its
`origin` to a typo would simply stop getting a vhost and a certificate, and on an HSTS-preloaded domain (G7) that is
an outage found by a user rather than by a run. A partially-specified entry fails the run instead.

No new field marks a headless project — **absence is the marker**. A `public: false` flag was considered and rejected:
it would be a second thing to keep in step with the fields it describes, and it can disagree with them, whereas the
coherence assert already provides the fail-fast property the flag would only restate.

## 5.4 Instance configuration

```hcl
resource "aws_lightsail_instance" "app" {
  name              = var.instance_name
  availability_zone = var.availability_zone
  blueprint_id      = var.blueprint_id   # "ubuntu_24_04"
  bundle_id         = var.bundle_id      # "small_3_0" — 2 GB / 2 vCPU / 60 GB, $12/mo
  key_pair_name     = aws_lightsail_key_pair.main.name
  user_data         = file("${path.module}/bootstrap.sh")

  add_on {
    type          = "AutoSnapshot"
    snapshot_time = "06:00"
    status        = "Disabled" # rev 2.5 — weekly cadence instead, see §5.8
  }
}
```

*Amended in rev 2.5:* the add-on is **disabled**. It is daily-only — its schedule takes a time of day and nothing
else, and its retention is fixed at the seven most recent — so the weekly Sunday cadence lives outside it, in §5.8.
The block stays in the resource (with `snapshot_time` still set, which the block requires) so re-enabling is a
one-word change.

Verify blueprint and bundle IDs before applying — they change over time:

```bash
aws lightsail get-blueprints --query 'blueprints[?platform==`LINUX_UNIX`].[blueprintId,name]' --output table
aws lightsail get-bundles    --query 'bundles[].[bundleId,ramSizeInGb,price]' --output table
```

## 5.5 Firewall

Ports 80 and 443 open to the world — 80 is required for Let's Encrypt HTTP-01 on the origin hostnames, and neither can
be restricted to CloudFront (G11). Port 22 restricted to `var.ssh_allowed_cidrs`, never `0.0.0.0/0`.

## 5.6 DNS

Route 53, not Lightsail DNS. The apex `A ALIAS → CloudFront` record already exists and **does not change** during the
migration — only the distribution's origin does. Each project additionally gets:

```hcl
resource "aws_route53_record" "origin" {
  for_each = local.origin_projects   # rev 2.10 — projects declaring an `origin`, not all of them
  zone_id  = local.zone_id
  name     = each.value.origin
  type     = "A"
  ttl      = 300
  records  = [aws_lightsail_static_ip.app.ip_address]
}
```

A **headless** project (§5.3 rev 2.10) has no `origin`, so it appears in neither `local.origin_projects` nor
`local.edge_projects` and produces no DNS record at all. Static sites that are not projects — the CDN (§4) and the
legal pages (§5.11) — carry their own alias records instead, since they have no instance origin to point at.

## 5.7 Backup bucket

A Lightsail bucket on the `small_1_0` bundle — 5 GB, $1/mo, matching [§14](14-cost.md). Versioning is enabled so an
overwritten dump is still recoverable.

```hcl
resource "aws_lightsail_bucket" "backups" {
  name      = var.backup_bucket_name   # globally unique
  bundle_id = "small_1_0"
}
```

**There is no access key anywhere.** Lightsail buckets support *resource access* — the service's equivalent of an EC2
instance profile — so the host is attached to the bucket and the AWS CLI resolves short-lived credentials from instance
metadata (G5):

```hcl
resource "aws_lightsail_bucket_resource_access" "backups_host" {
  bucket_name   = aws_lightsail_bucket.backups.name
  resource_name = aws_lightsail_instance.app.name
}
```

Nothing to store in Vault, nothing to rotate, and revocation is detaching the instance. `aws_lightsail_bucket_access_key`
is deliberately unused: its `secret_access_key` is a plain `computed` attribute and would sit in state in cleartext.

Constraints: instance and bucket must share a Region, the instance must be running or stopped, and the grant is
whole-bucket read/write with no way to narrow it to a prefix. **It also requires the metadata guard in the `docker`
role — see G16**, without which every container can read the same credentials.

Lightsail buckets have no lifecycle rules, so retention is the backup script's job — see [§9.2](09-ansible.md).

## 5.8 Weekly snapshots (rev 2.5)

The AutoSnapshot add-on cannot do weekly (§5.4), so snapshots are driven from the AWS side — where credentials exist
without putting any on the host (G5):

```
EventBridge rule  cron(0 6 ? * SUN *)          # Sundays 06:00 UTC = 01:00 GMT-5, the old daily hour
  → Lambda <instance>-weekly-snapshot          # terraform/lambda/weekly_snapshot.py
      CreateInstanceSnapshot <instance>-weekly-<YYYY-MM-DD>
      then delete all but the newest KEEP whose names start with `<instance>-weekly-`
```

- The snapshots it creates are **manual** snapshots — nothing in Lightsail expires them; the prune step is the only
  bound on their cost (G20).
- The prune filters strictly by the `<instance>-weekly-` prefix, so hand-made snapshots (`pre-harden-*`, future
  pre-change snapshots) are never candidates.
- Retention is the Lambda's `KEEP` env var — 4, about a month. Snapshots are incremental, so four weeklies cost
  roughly what seven dailies did; this is a cadence change more than a cost change (§14).
- The Lambda's role holds exactly `lightsail:CreateInstanceSnapshot`, `lightsail:GetInstanceSnapshots`,
  `lightsail:DeleteInstanceSnapshot` and CloudWatch Logs writes. Lightsail actions largely ignore resource-level
  ARNs, so the real scoping — the name prefix — lives in the code.
- Failure mode: if the Lambda breaks, snapshots stop being *created*, not just pruned. There is no alarm at this
  scale — glance at `aws lightsail get-instance-snapshots` when in doubt.

## 5.9 Container log shipping (rev 2.7)

Each project container logs to CloudWatch via Docker's `awslogs` driver (AD-11):

```hcl
resource "aws_cloudwatch_log_group" "project" {
  for_each          = local.projects
  name              = "/kenesparta/${each.key}"
  retention_in_days = 7   # the whole retention story — the driver never creates groups (G21)
}
```

plus one IAM user, `<instance>-logs-writer`, whose inline policy allows exactly `logs:CreateLogStream` and
`logs:PutLogEvents` on those groups and their streams — no `CreateLogGroup`, no reads. **No access key resource
exists**: the key is minted out of band (`aws iam create-access-key --user-name $(terraform output -raw
logs_writer_user)`) for the same reason the bucket access key never existed — the resource's secret half is a plain
`computed` attribute that would sit in state in cleartext (G5). The key goes into Vault (§9.4), and the `docker` role
deploys it as a `0600` systemd drop-in on `docker.service`; the daemon reads its AWS credentials from its environment.

Driver options, set per service by the deploy role's Compose template: `awslogs-region` (must match `var.region` —
hand-copied between the stages like `backup_bucket`, because Ansible does not read state), `awslogs-group` as above,
`awslogs-stream` named after the container, and `mode: non-blocking` with a 4 MB buffer — G21 explains why blocking is
wrong here. `docker logs` keeps working through Docker's dual-logging cache. Caddy and Postgres stay on the daemon's
`json-file` default; only project containers ship.

## 5.10 Edge telemetry headers (rev 2.8, amended 2.9)

AD-12: every distribution injects the viewer's IP and geolocation as headers so the applications can log them
(§5.9 ships the logs). Two resources in `cloudfront.tf`, attached to the default cache behavior of the blog
singleton and every per-project distribution alike:

```hcl
resource "aws_cloudfront_function" "true_client_ip" {
  name    = "kenesparta-true-client-ip"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = file("${path.module}/true-client-ip.js") # sets true-client-ip from event.viewer.ip
}

resource "aws_cloudfront_cache_policy" "disabled_plus_geo" {
  name = "kenesparta-caching-disabled-plus-geo"
  # Near-CachingDisabled: min/default TTL 0, max_ttl 1, accept-encoding flags
  # off. Whitelisted headers ride the cache key only to be forwarded to the
  # origin: CloudFront-Viewer-Country, -Country-Region-Name, -City, plus
  # Authorization; query strings all. See the caveats below for why max_ttl
  # is 1 and why Authorization/query strings are in the key.
}
```

The behavior keeps `Managed-AllViewerExceptHostHeader` as its origin request policy (the Host exclusion is
load-bearing — AD-8) and swaps `cache_policy_id` from the managed `CachingDisabled` to the custom policy, plus a
`function_association { event_type = "viewer-request" }`.

Caveats: CloudFront percent-encodes non-ASCII header values (RFC 3986) — consumers decode; city/region resolution is
best-effort (some IPs only geolocate to a country) and the `-Country-Region-Name` family is not applied to requests
originating from the AWS network, so applications must treat every geo field as optional.

**As applied (2026-08-01, rev 2.9):** the TTL-0 + whitelist combination this section originally specified is
rejected by the API after all (`CreateCachePolicy` → `InvalidArgument: The parameter HeaderBehavior is invalid for
policy with caching disabled`), so the anticipated fallback is the config: `min_ttl = 0`, `default_ttl = 0`,
`max_ttl = 1`. Nothing is cached unless the origin volunteers a `Cache-Control`, and then for at most one second.
Because that formally *enables* caching, two hardenings ride along: `Authorization` joins the header whitelist —
in-key it is guaranteed into origin requests, sidestepping CloudFront's special GET/HEAD treatment of that header on
caching-enabled behaviors, which would otherwise threaten the budget API's bearer auth — and query strings switch to
`all`, so a one-second entry is keyed on the exact request rather than shared geo-wide. Cookies stay out of the key
(the ORP still forwards them): a response that is simultaneously public-cacheable and cookie-varying could collide
within that second, and no current origin emits one — revisit if one ever does.

Observed after deploy (Caddy access log, 2026-08-01): referencing any `CloudFront-Viewer-*` header in the cache
policy makes CloudFront inject the *whole* header family into the viewer request, and the all-except-Host ORP then
forwards every one of them — the origin also sees `-Address`, `-ASN`, `-Latitude`/`-Longitude`, `-Time-Zone`,
`-Country-Name` and the device-type family, not just the three whitelisted names. Undocumented enrichment, not
contract: applications may only rely on the whitelisted three plus `true-client-ip`.

## 5.11 Application legal pages — `cnayp-bot.kenesparta.dev` (rev 2.11)

Discord requires a **Terms of Service** URL and a **Privacy Policy** URL as a precondition for verifying or listing an
application, and fetches both itself. `cnayp-bot.kenesparta.dev` serves them from **S3 + CloudFront**, not from the
instance:

```
cnayp-bot.kenesparta.dev  →  CloudFront (wildcard ACM)  →  OAC  →  s3://kenesparta-cnayp-bot-site
```

The bot does **not** serve its own legal pages. `cnayp_discord_bot` is headless (§5.3 rev 2.10), and giving it these
two documents would mean an `origin-*` hostname, a Caddy vhost and a Let's Encrypt certificate against the shared
50/week budget (G8), one of C3's four service slots, and — the part that actually decides it — documents Discord
fetches whose availability is bound to a bot process on a 2 GB box. A static site costs no RAM and is unaffected by
anything that happens to the instance.

Shaped after `static-cdn.tf` (§4), with four deliberate differences:

| | `cdn.kenesparta.dev` | `cnayp-bot.kenesparta.dev` | Why |
|---|---|---|---|
| Bucket name | dotted | `kenesparta-cnayp-bot-site` | Dots add labels to the S3 REST endpoint that the wildcard cert does not cover. The CDN's name is inherited; `kenesparta-infra-backups` is the newer convention. |
| Public access block | all false | all true | OAC is the only read path. A service principal with a `SourceArn` condition is not a *public* policy, so `block_public_policy` can stay on. |
| Versioning | off | **on** | These are legal documents: showing what the policy said on a date is the point, and a bad `s3 sync --delete` stays recoverable. |
| Immutable behavior | `fonts/*`, `blog/*` | **none, ever** | See below. |

**G19 in reverse — no immutable path may ever exist here.** The CDN's year-long `immutable` cache is safe on
filename-versioned, write-once assets. A Terms of Service and a Privacy Policy are the exact opposite: stable names,
overwritten in place, and the whole purpose of updating one is that readers see the new text. `immutable` cannot be
invalidated out of a browser, so putting these documents behind it would mean a reader holding a superseded privacy
policy for a year with no way to reach them. The cache policy is therefore `min_ttl = 0`, `default_ttl = 300`,
`max_ttl = 3600`, and the CI role holds `cloudfront:CreateInvalidation` on this distribution so a correction lands in
seconds rather than minutes.

**A missing object returns 403, not 404.** The distribution is not granted `s3:ListBucket`, so S3 will not distinguish
"absent" from "forbidden". Both codes are mapped to `/404.html`, which makes that file a **required** member of the
upload set — CloudFront falls back to its own generic error page if it is absent. The published set is therefore
`index.html`, `terms.html`, `privacy.html`, `404.html`.

**Publishing is OIDC, and the role is its own.** `github-actions-cnayp-bot-site` trusts
`repo:kenesparta/cnayp-discord-bot` on `main` and tags only, and grants `s3:PutObject`/`s3:DeleteObject` on that one
bucket plus invalidation on that one distribution. It is deliberately **not** a fourth `sub` on
`github-actions-ecr-ecs-deploy`: that role carries `cdn-bucket-write-policy`, so extending its trust policy would hand
a Discord bot's CI write access to the CV and the blog's assets — an authorization change made invisibly, by editing a
list of repository names. Fork pull requests present a `sub` of `repo:...:pull_request`, matching neither pattern, so
an untrusted PR cannot publish. No access key exists on either side.
