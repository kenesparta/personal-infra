# 8. Outputs

| Name             | Purpose                              |
|------------------|--------------------------------------|
| `static_ip`      | For DNS verification and SSH         |
| `instance_name`  | For `aws lightsail` CLI calls        |
| `ssh_command`    | Convenience: `ssh ubuntu@<ip>`       |
| `backup_bucket`  | For the `pg_dump` timer              |
| `cdn_domain`     | Existing, unchanged                  |
| `logs_writer_user` | IAM user whose key is minted out of band for the `awslogs` driver (§5.9, G21) |

Do not output secrets. The origin secret is never an output.
