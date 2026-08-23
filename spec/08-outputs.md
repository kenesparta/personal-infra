# 8. Outputs

| Name             | Purpose                              |
|------------------|--------------------------------------|
| `static_ip`      | For DNS verification and SSH         |
| `instance_name`  | For `aws lightsail` CLI calls        |
| `ssh_command`    | Convenience: `ssh ubuntu@<ip>`       |
| `backup_bucket`  | For the `pg_dump` timer              |
| `cdn_domain`     | Existing, unchanged                  |
| `logs_writer_user` | IAM user whose key is minted out of band for the `awslogs` driver (§5.9, G21) |
| `auruming_nameservers` | The four Route 53 nameservers to paste into Namecheap — step 3 of G23 |
| `auruming_ds_record`   | The DNSSEC delegation-signer record to paste into Namecheap — step 6 of G23, and only after step 4 |
| `auruming_cdn_bucket` / `auruming_cdn_distribution_id` / `auruming_cdn_domain` | The asset CDN (§5.13) — upload target, invalidation target, public hostname |

Do not output secrets. The origin secret is never an output.

Neither `auruming.com` output is a secret: nameservers and a DS record are published in the public DNS by design —
the DS is a hash of a public key, and its whole purpose is to be readable by every resolver on the internet. They are
outputs because they are the two values a human has to retype into a registrar dashboard, and `make dns/auruming`
prints them together in the order G23 needs them.
