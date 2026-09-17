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
from this file (blog keeps the migrated singleton distribution in `cloudfront.tf`). Each rides the wildcard ACM
certificate of the registered domain it names in `domain`, so `hostname` must stay within that domain or its apex
(rev 2.12 — through rev 2.11 there was one certificate and `hostname` had to be `kenesparta.dev` or a label under it).

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
    LOG_LEVEL: info                  # not RUST_LOG — this project is Go (log/slog)
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

*Amended in rev 2.12 — the `domain` field (AD-13):* a second registered domain, `auruming.com`, now has its own
zone, its own DNSSEC key and its own certificate (§5.12). A project therefore has to say **which** registered domain
its names belong to, because `hostname` and `origin` alone cannot be resolved to a zone or a certificate without
parsing them — and parsing a name to find its zone is exactly the guess this file exists to avoid.

```yaml
- name: auruming
  domain: auruming.com              # the registered domain: selects the zone AND the ACM certificate
  hostname: auruming.com            # CloudFront alias, must sit within `domain`
  origin: origin.auruming.com       # A record -> static IP, Caddy vhost + LE cert, also within `domain`
  image: ghcr.io/kenesparta/auruming
  port: 3002
  database: auruming
```

`domain` joins `hostname`, `origin` and `port` as a **fourth member of the ingress set** — all four together, or none
of them. It is not defaulted to `var.primary_dns`, for the same reason nothing else in the set is defaulted: a
project under `auruming.com` that lost the field to a typo would create its records in the `kenesparta.dev` zone and
present the wrong certificate, and the first symptom is a name that does not resolve. §9 asserts `0 or 4`, and
Terraform's `local.domains` lookup fails the plan on a `domain` that names no known zone. A headless project (rev
2.10) has no names at all and therefore no `domain`.

Terraform only ever reads `domain` through `local.domains`; Ansible does not read it at all — Caddy's vhost is keyed
on `origin`, which is already fully qualified. It is asserted on the Ansible side regardless, so that a
`projects.yml` which would fail `terraform plan` also fails `make configure`, rather than the two tools disagreeing
about whether the file is valid.

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
  zone_id  = local.domains[each.value.domain].zone_id   # rev 2.12 — per-domain, not local.zone_id
  name     = each.value.origin
  type     = "A"
  ttl      = 300
  records  = [aws_lightsail_static_ip.app.ip_address]
}
```

A **headless** project (§5.3 rev 2.10) has no `origin`, so it appears in neither `local.origin_projects` nor
`local.edge_projects` and produces no DNS record at all.

*Amended in rev 2.12 (AD-13):* there is more than one zone now, so every per-project record resolves its zone through
`local.domains[each.value.domain]` rather than the single `local.zone_id`. `local.zone_id` survives, unchanged, for
the things that genuinely are `kenesparta.dev`-only: the ACM validation records for that domain's certificate, the
Proton mail and Discord records (§5.6 below), the CDN, and the legal-pages site (§5.11). An unknown `domain` is a
plan-time failure on the map lookup, not a record created in the wrong place. Static sites that are not projects — the CDN (§4) and the
legal pages (§5.11) — carry their own alias records instead, since they have no instance origin to point at.

### 5.6.1 DNSSEC delegation state (rev 2.15, completed 2026-08-23)

Every zone in this account is signed by Route 53 — KSK in KMS, `ECDSAP256SHA256`, one KSK per zone — and, **since
2026-08-23, every one is also validated**, because the DS record is finally published in each parent zone.

That distinction is the whole point of this subsection. Signing and validation are separate halves in separate
places: Route 53 signs the zone and publishes `DNSKEY`/`RRSIG`, but the **DS record lives in the PARENT zone**
(`.dev`, `.link`, `.com`), which only the registrar can write to. Until 2026-08-23 no DS existed for any domain, so
all three zones were signed and **none was enforced** — resolvers had nothing telling them to check the signatures.
Earlier revisions of this spec described the zones as "DNSSEC-signed", which was true and easy to misread as
"protected". They were not.

Published DS records, verified byte-identical against `aws route53 get-dnssec` on 2026-08-23:

| Zone | Key Tag | Alg | Digest type | Digest | Registrar |
|---|---|---|---|---|---|
| `kenesparta.dev` | 29022 | 13 | 2 | `73DF0CB7E80EFF7C6A03D67E8767131E319768166E75ADC27C6B0E8B83C9110F` | not Route 53 |
| `kecc.link` | 65505 | 13 | 2 | `F08C0C6528CA3EC379D47A86EF905EB86CD0E6B56C502FE9C9D46E41CB7C77A0` | Namecheap |
| `auruming.com` | 189 | 13 | 2 | `34CF40A9B30D3017253628CB6053ECB53A10F8BD87ACD43C54A966D10F513558` | Namecheap |

Algorithm 13 is ECDSA P-256 with SHA-256; digest type 2 is SHA-256. These values are **derived from the KSK**, not
chosen — reproduce them at any time with:

```bash
aws route53 get-dnssec --hosted-zone-id <zone> --query 'KeySigningKeys[0].DSRecord' --output text
```

They are not secrets (§8): a DS is a hash of a public key whose entire purpose is being readable by every resolver.

**A DS is only valid for the KSK it was derived from.** Rotating or replacing a key-signing key therefore requires
publishing the new DS at the registrar *before* retiring the old key, and Terraform cannot do that step for any of
these domains — AWS registers none of them (`aws route53domains list-domains` returns empty), so the registrar is the
only channel to the parent. Destroying and recreating a KSK without that ordering is the G23 outage in its most
avoidable form.

**AWS could own this step only by being the registrar.** Route 53 Domains exposes
`aws_route53domains_delegation_signer_record` (present in the pinned provider), which pushes a DS to the registry for
domains it sponsors. Using it would mean transferring registration, which is a registrar migration and not a config
change. Rejected as disproportionate: the manual step happens once per KSK, which is approximately never.

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
  # ON (rev 2.21, G30). Whitelisted headers ride the cache key only to be
  # forwarded to the origin: CloudFront-Viewer-Country, -Country-Region-Name,
  # -City, plus Authorization; query strings all. See the caveats below for why
  # max_ttl is 1, why Authorization/query strings are in the key, and why the
  # accept-encoding flags are not optional.
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

**Amended in rev 2.21 — the accept-encoding flags are on.** This section shipped them off, as the managed
`CachingDisabled` policy has them, and nothing downstream was ever compressed as a result (G30): with both flags off
CloudFront leaves `Accept-Encoding` out of the origin request — the all-except-Host ORP does not put it back — so no
application ever learned that the viewer could decompress anything, and the behaviors' `compress = true` never had a
`Content-Length` to work with. Found through a Lighthouse audit of `auruming.com` ("No compression applied") on
2026-09-17, while that app's own `CompressionLayer` was demonstrably working. With both flags on, CloudFront forwards
a normalized `br,gzip` (or whichever of the two the viewer offered) and puts the same value in the cache key. The key
change is inert here — nothing lives in this cache longer than a second — and the forwarding is the point. It applies
to every distribution on this policy at once: the blog, the budget API and `auruming.com`. An origin that compresses
now reaches the viewer compressed; one that does not answers as before, and where that answer carries a
`Content-Length` CloudFront may now compress it at the edge. Either way the client decodes it transparently, which is
what `Accept-Encoding` promised in the first place.

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

## 5.12 The `auruming.com` estate (rev 2.12)

A second registered domain, served by the same host, isolated from `kenesparta.dev` everywhere isolation is free
(AD-13). The public shape is identical to any other project — the AD-8 chain is unchanged:

```
auruming.com  →  CloudFront (ACM: auruming.com + *.auruming.com)
              →  origin.auruming.com  →  Caddy (Let's Encrypt)  →  auruming:3002
```

What is new is everything *behind* the name:

| Concern              | `kenesparta.dev`                          | `auruming.com`                              |
|----------------------|-------------------------------------------|---------------------------------------------|
| Hosted zone          | `aws_route53_zone.kenespartadev`          | `aws_route53_zone.auruming`                 |
| DNSSEC signing       | own KSK + own KMS key                     | own KSK + own KMS key — no sharing          |
| ACM certificate      | apex + `*.kenesparta.dev`                 | apex + `*.auruming.com`                     |
| Let's Encrypt budget | 50/week shared by every `origin-*` name   | its own 50/week (limits are per registered domain — G8) |
| Registrar            | Route 53                                  | **Namecheap** — see G23                     |
| Mail                 | Proton (MX/SPF/DKIM/DMARC — §5.6)         | none; no mail records are created           |

**Terraform files.** `dns-auruming.tf` (zone, DNSSEC, KSK, KMS key) and `acm-auruming.tf` (certificate + validation),
both written longhand in the same shape as `dns.tf` and `acm.tf`. Deliberately separate files rather than appended
sections: the two estates have independent lifecycles, and a file boundary is the cheapest way to make a diff that
touches `auruming.com` obviously not touch the zone that carries mail (G10).

**Its DNSSEC key is its own.** A KMS key costs $1/month and Route 53 permits one key-signing key to sign only the
zone it is attached to, so there was never a sharing option to reject at the AWS level — but the property is worth
stating: rotating or disabling signing on one domain cannot affect the other, and a KMS key scheduled for deletion
takes exactly one zone with it.

**Log group naming stays `/kenesparta/<project>`.** The prefix is the *account's* namespace, not the domain's — it is
a constant shared by `cloudwatch-logs.tf` and `cloudwatch_log_group_prefix` in `group_vars/all.yml` (§5.9), and it is
matched by the logs-writer IAM policy's `/kenesparta/*` resource scope. Renaming it per-domain would mean a second
policy statement, a second Ansible variable, and a per-project conditional in the deploy role's Compose template, to
change a string nobody reads except in the CloudWatch console. `/kenesparta/auruming` it is.

**The apply is two-stage, and the first stage is the registrar's.** `aws_acm_certificate_validation` blocks until the
CNAME it wrote is publicly resolvable, and nothing under `auruming.com` is publicly resolvable until Namecheap
delegates to the new Route 53 nameservers. A single `terraform apply` therefore sits and eventually times out. The
ordering is in G23: `make dns/auruming-zone` creates the zone alone, and `make dns/auruming` prints both values the
registrar needs.

**Port 3002.** Not 3000, because `blog` holds it and §9's pre-task asserts ports are unique across projects; and
deliberately not 3001, which is Leptos's **default reload port**. The app's `shell()` renders `<AutoReload>`, which
emits a live-reload websocket script whenever `LEPTOS_ENV` is `DEV` — so the image sets `LEPTOS_ENV=PROD`, and the
port is chosen so that a build which ever loses that variable fails visibly against a closed port rather than
confusingly against its own. The number is container-internal (nothing publishes it — acceptance criterion 9) and
matters only as a Caddy upstream.

**This is C3's fourth and last service.** `blog`, `budget`, `cnayp_discord_bot`, `auruming` fills the RAM budget AD-1
sized for `small_3_0`: ~350 MB OS+Docker, ~400 MB Postgres, ~50 MB Caddy, 4 × ~100 MB ≈ 1.2 GB of 2 GB. A fifth
project is a bundle change to `medium_3_0` on a snapshot, not an entry in `projects.yml`; §9's assert refuses the
fifth entry rather than letting the OOM killer discover it.

## 5.13 `cdn.auruming.com` — static asset CDN (rev 2.13, amended 2.20)

An **asset** CDN for `auruming.com` — fonts, images, video and similar media — served from S3 + CloudFront rather
than by the site container. It is not a website, but since rev 2.20 it carries an empty `index.html` as
`default_root_object`, exactly as `cdn.kenesparta.dev` does, so that opening the bare hostname answers `200` rather
than S3's `AccessDenied` XML (see the amendment at the end of this section). Same reasoning as §5.11: bytes served from S3 cost
no RAM against AD-1's budget, occupy none of C3's four slots, and stay up when the instance does not. Serving a video
off a 2 GB shared box is the case where that stops being a nicety.

```
cdn.auruming.com  →  CloudFront (ACM: *.auruming.com)  →  OAC  →  s3://auruming-cdn
```

It is the third static site in the estate, and it is shaped after **`static-cnayp-bot.tf`, not `static-cdn.tf`**. That
distinction is the whole design note:

| | `cdn.kenesparta.dev` | `cdn.auruming.com` | Why |
|---|---|---|---|
| Bucket name | `cdn.kenesparta.dev` (dotted) | `auruming-cdn` | Dots add labels to the S3 REST endpoint that the `*.s3.<region>.amazonaws.com` certificate does not cover — a TLS/SigV4 edge case worth not owning. The CDN's dotted name is **inherited** from the pre-migration estate, not a pattern to copy (§5.11). Nobody sees it; the public name is the CloudFront alias. |
| Public access block | all `false` | all `true` | Also inherited. OAC is the only read path, so no public ACL or policy is ever needed. `block_public_policy` can stay on: a service principal with a `SourceArn` condition is not a *public* policy. |
| Certificate | referenced directly | via `aws_acm_certificate_validation.auruming` | On a from-zero apply a certificate ARN is known before the certificate is *usable*; referencing the validation resource is what orders the distribution after issuance. The older files predate that concern and their certificates are long since issued. |
| Immutable behavior | `fonts/*`, `blog/*` | **none — see below** | |

**No immutable cache behavior exists here, deliberately (G19).** The `fonts/*` and `blog/*` behaviors on
`cdn.kenesparta.dev` are safe only because those paths are filename-versioned and write-once. Creating the equivalent
on an **empty** CDN would commit a path prefix to a year-long, uninvalidatable browser cache before a single object
has been published to it — a trap laid for whoever first uploads a stable-name file under `fonts/`. The default
behavior instead carries `Cache-Control: public, max-age=86400` with `override = false`, so a deliberate per-object
`Cache-Control` set at upload time wins at both the edge (`min_ttl = 0`) and the browser. That is strictly more
flexible than a path-scoped immutable policy and has no cliff.

Adding an immutable behavior later is a deliberate act with a precondition: the path must be filename-versioned, and
the objects under it must never be overwritten in place. Rename to replace.

**Cache defaults are tuned for media, not documents.** One day at the browser (`public, max-age=86400`,
`override = false`) and one day at the edge (`default_ttl`), with `min_ttl = 0` so a deliberately short per-object
`Cache-Control` still wins, and `max_ttl = 31536000` as headroom for an object that asks for more. Media is replaced
rarely and deliberately; a day is long enough to be a real cache and short enough that a mistake ages out on its own,
which is precisely what `immutable` does not do.

**Byte-range requests need no configuration.** Seeking within a video is a ranged `GET`, which CloudFront handles
against an S3 origin automatically. `allowed_methods` is `GET`/`HEAD`/`OPTIONS`: this distribution serves bytes and
never accepts them.

**`PriceClass_100` excludes South America.** It matches every other distribution here and is the cheapest tier (C1),
but for media specifically it is worth knowing that a viewer in Lima is served from a North American edge — a longer
first byte, not a failure. Only `PriceClass_All` adds South American edges. That is a cost decision, not a
correctness one, and it is a one-word change.

**CORS is present**, unlike §5.11's legal pages, and since rev 2.20 it allows `*`, as `cdn.kenesparta.dev` does.
Plain `<img>` and `<video>` tags need no CORS at all; fonts, `fetch`, and canvas-read pixels do, and fonts are the case
that decided this. Rev 2.13 scoped it to `https://auruming.com` alone, which meant a font served from here loaded on
exactly that origin and nowhere else — not on a local dev server, not on any other property — and the failure
presents as a console full of CORS errors, which is to say as the CDN being unreachable. Every object here is public
and `Access-Control-Allow-Credentials` is off, so an allowlist of one origin withheld nothing from anyone who could
type a URL; it only withheld the assets from browsers. Nothing else in the policy changed.

**Nothing can publish to it yet, on purpose.** No IAM role is created here. Which repository publishes, on which refs,
is an authorization decision, and §5.11 records why those are made explicitly and one-role-per-repo-per-bucket rather
than by appending a `sub` to an existing role. Until one exists, uploads are a manual `aws s3 sync` under the SSO
admin profile, which is appropriate for a CDN with no automated producer.

**Amended in rev 2.20 — open to the internet, like its sibling.** Two of the differences from `cdn.kenesparta.dev`
that rev 2.13 introduced on purpose were the two things that made this CDN look broken on the day it was first used:
a bare `/` returned S3's `AccessDenied` XML, and a font loaded from anywhere but `https://auruming.com` was
CORS-blocked. Both now match the older CDN — `default_root_object = "index.html"` and
`Access-Control-Allow-Origin: *` — which makes an empty **`index.html` a required member of the upload set** (it was
uploaded 2026-09-04; delete it and `/` is a 403 again). What did **not** change is the immutable behavior: the
`fonts/` prefix now exists, and the precondition above still stands. A font that wants a year in the browser gets it
per object, at upload time:

```bash
aws s3 cp solway-v19-latin-regular.woff2 s3://auruming-cdn/fonts/ \
  --content-type font/woff2 \
  --cache-control 'public, max-age=31536000, immutable' \
  --profile "$TF_VAR_aws_sso_profile"
```

The default behavior honours that at both the browser (`override = false`) and the edge (`min_ttl = 0`,
`max_ttl = 31536000`), so it is the year-long cache without the path-level cliff — and it is only ever right for a
filename-versioned object (the `-v19-` in the example is the version). Pass `--content-type` explicitly rather than
trusting the uploader's guess: `cdn.kenesparta.dev`'s fonts are served as `application/x-www-form-urlencoded` today
because whatever uploaded them guessed. Browsers sniff fonts so it is harmless there, but it is wrong, and this CDN
sends `X-Content-Type-Options: nosniff`.

## 5.14 HTTP/3 at the edge (rev 2.14)

Every distribution sets `http_version = "http2and3"`. Until rev 2.13 none of them set it at all, so all six took the
CloudFront default of `http2` and no viewer ever attempted QUIC.

`http2and3` is **additive, not a switch**: a client that speaks HTTP/3 gets it, everything else negotiates HTTP/2 or
HTTP/1.1 exactly as before. There is no cost change — CloudFront bills per request and per GB, not per protocol — and
no cache, origin or certificate implication. The origin leg is untouched: CloudFront talks to a custom origin over
HTTP/1.1 regardless of what viewers use.

The measurable benefit is on lossy, high-latency links: QUIC has no TCP head-of-line blocking and a shorter handshake.
That matters most for `cdn.auruming.com`, where media is served to viewers in South America from North American edges
(§5.13 — `PriceClass_100` has no South American presence), and it is exactly the case where the extra round trips of
TCP + TLS are most visible.

**The Caddy container's `443/udp` publish is unrelated, and has never served a viewer.** `roles/caddy/templates/
docker-compose.yml.j2` maps `443:443/udp` and comments it `HTTP/3`, which is true of Caddy in isolation and
misleading in this architecture: the only route to that port is `origin-<project>.<domain>`, and AD-8 exists to
ensure nothing but CloudFront ever connects there — over HTTP/1.1. Enabling HTTP/3 at the distribution is what
actually gives viewers QUIC. The UDP publish is left in place (it costs nothing and would matter if a project were
ever served directly) but it is not the reason HTTP/3 works, and reading it as such is the trap this paragraph
exists to close.

**Verifying it:** a distribution with HTTP/3 enabled advertises `alt-svc: h3=":443"`. That header is how a browser
discovers QUIC at all, so its presence — not a successful `curl --http3` — is the real check, and it is observable
from any client:

```bash
curl -sS -o /dev/null -D - https://auruming.com | grep -i alt-svc
```

## 5.15 Branded origin-failure pages (rev 2.18)

Until rev 2.18 an unreachable origin produced CloudFront's own `504 Gateway Timeout ERROR` page — the AWS wordmark, a
request ID, and an invitation to "contact the app or website owner". Observed live on `auruming.com` during the
2026-09-01 reboot window. The app distributions carried **no** `custom_error_response` at all; the only ones in the
estate were the legal site's 403/404 (§5.11).

**Shape.** One S3 bucket per registered domain, OAC-locked, added as a *second origin* to every app distribution of
that domain, plus an ordered behavior and three error mappings:

| Piece | Value |
|---|---|
| Buckets | `kenesparta-status-pages`, `auruming-status-pages` — undotted, for the reason in §5.11 |
| Behavior | `/__status/*` → the status origin, cached (min 0 / default 300 / max 3600) |
| Key layout | `__status/<hostname>/maintenance.html` — one page per site, not one shared page |
| Mapped codes | 502, 503, 504 → `response_code = 503`, `error_caching_min_ttl = 10` |

**Why 502/503/504 and deliberately not 500.** Those three are what CloudFront emits when it cannot get a usable
answer *from* the origin — box down, Caddy down, TLS handshake failed, timeout — and replacing them loses nothing,
because the body was AWS boilerplate either way. A 500 is different: it is the application's own response, carrying
the application's own body. `api.kenesparta.dev` returns JSON errors to an iOS client, and a `custom_error_response`
on 500 would replace that JSON with an HTML page for every server-side bug. The line is "CloudFront could not reach
an application" versus "the application answered".

**Why `error_caching_min_ttl = 10` and not the default.** The default is **300 seconds**. Left alone, the maintenance
page keeps being served for five minutes *after* the site is healthy — the recovery is invisible and the outage looks
five minutes longer than it was. Ten seconds is long enough to shield the origin from a retry storm and short enough
that recovery shows up as fast as a viewer can press reload.

**Why `response_code = 503` and not 200.** 503 is the honest status and the one crawlers treat as "come back later".
Serving a maintenance page as 200 invites it to be indexed as the site's real content.

**Why one page per hostname.** `projects.yml` describes three public sites with nothing in common but their operator;
a single shared page would have to be generic enough to be true of all of them, which is how maintenance pages end up
saying nothing. The pages live at the repository root in `status-pages/<hostname>/` and are uploaded by
Terraform, not CI — they are a few KB, they change roughly never, and they must exist before the outage that needs
them. Root, not `terraform/`, because Ansible reads the same files to serve them from Caddy (§9.8, rev 2.19): one
authority, two consumers, exactly like `projects.yml`.

**Self-contained is a requirement, not a preference.** Every page inlines its CSS and uses no image, font, or script
from anywhere. An external asset referenced from the maintenance page would be fetched from the same dead origin and
fail alongside it (G28).

The legal site (§5.11) is deliberately untouched: its origin is S3, so it has no origin to fail, and its existing
403/404 → `/404.html` mapping already covers the only errors it can produce.
