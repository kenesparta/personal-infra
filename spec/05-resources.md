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
  `X-Origin-Verify` header themselves in addition to Caddy's gate (the budget bot's `ORIGIN_SECRET`). One source,
  no second copy to rotate (G13).

Each **non-blog** project gets its own CloudFront distribution and `hostname` alias records generated from this file
(blog keeps the migrated singleton distribution in `cloudfront.tf`). All of them ride the wildcard ACM certificate —
`hostname` must stay within `*.kenesparta.dev` (or the apex).

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
    status        = "Enabled"
  }
}
```

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
  for_each = { for p in local.projects : p.name => p }
  zone_id  = local.zone_id
  name     = each.value.origin
  type     = "A"
  ttl      = 300
  records  = [aws_lightsail_static_ip.app.ip_address]
}
```

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
