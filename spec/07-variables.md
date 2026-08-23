# 7. Variables

| Name                 | Type         | Default          | Notes                                  |
|----------------------|--------------|------------------|----------------------------------------|
| `region`             | string       | `us-east-1`      |                                        |
| `availability_zone`  | string       | —                | e.g. `us-east-1a`                      |
| `instance_name`      | string       | `kenesparta-host`| **Not** `kenesparta-app` — the container service holds that name and both coexist until Phase 7 |
| `blueprint_id`       | string       | `ubuntu_24_04`   | Verify against `get-blueprints`        |
| `bundle_id`          | string       | `small_3_0`      | 2 GB / 2 vCPU / 60 GB / 3 TB — see AD-1 |
| `primary_dns`        | string       | `kenesparta.dev` |                                        |
| `link_dns`           | string       | `kecc.link`      |                                        |
| `auruming_cdn_bucket_name` | string  | `auruming-cdn`   | Asset CDN bucket (§5.13). Undotted on purpose — dots break the S3 REST endpoint's certificate |
| `auruming_dns`       | string       | `auruming.com`   | Second registered domain (rev 2.12, AD-13). Registered at **Namecheap**, not Route 53 — the delegation and the DS record are manual (G23) |
| `ssh_public_key_path`| string       | `~/.ssh/personal-infra.pub` | A **path**, not the key body: `.tfvars` cannot call functions, so the file is read by `file(pathexpand(...))` |
| `ssh_allowed_cidrs`  | list(string) | —                | Home/office IPs. Never `["0.0.0.0/0"]` |
| `backup_bucket_name` | string       | —                | Globally unique                        |
| `aws_sso_profile`    | string       | `""`             | Local runs only                        |

The CloudFront origin secret is **not** a plain variable — it is read from `secrets/prod.enc.env` via the sops provider,
matching how the existing stack handles `DATABASE_URL`.
