# 1. Purpose

Provision and version-control the infrastructure for a single Lightsail **instance** that hosts several independent Rust
services behind one reverse proxy, with a self-hosted PostgreSQL instance and off-host backups.

This revision also absorbs an existing, working estate. `kenesparta.dev` currently runs on a **Lightsail Container
Service** (`nano`, ~$7/mo) fronted by CloudFront, pulling a private ECR image, backed by a **Lightsail managed
PostgreSQL** created outside Terraform. That infrastructure lives in `kenesparta.dev/tf` with state at
`s3://tf.kenesparta.dev/dns/prod/kenesparta.dev`.

**After this migration, `kenesparta.dev/tf` is deleted** and `personal-infra` is the single Terraform state for the
account.

This spec is the source of truth. Implementation should not introduce resources or patterns not described here; if a
gap is found, amend the spec first.
