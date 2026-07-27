# 11. Acceptance Criteria

1. `terraform plan` on a clean checkout reports **no changes** after a successful apply.
2. A second consecutive `make configure` reports **zero `changed` tasks** (A1).
3. No secret appears in plaintext anywhere in either repository; `group_vars/vault.yml` is encrypted.
4. `kenesparta.dev` resolves through CloudFront and is served by the instance.
5. A direct request to any `origin-*.kenesparta.dev` without `X-Origin-Verify` returns 403.
6. Port 22 is unreachable from an IP outside `ssh_allowed_cidrs`.
7. Caddy serves valid Let's Encrypt certificates on every origin hostname.
8. Postgres is unreachable from off the host. Since AD-3 containerized it, `ss -tlnp` on the host shows **no** listener
   on 5432 at all — the socket lives in the container's namespace — and `docker compose ps` shows no published port.
   `psql` from any address other than the `web` network fails to connect.
9. No container publishes ports to the host except Caddy.
10. A `pg_dump` artifact exists in the backup bucket and has been restored successfully at least once.
11. Route 53 zones retain their original zone IDs and DNSSEC remains `SIGNED`; mail to the Proton addresses still
    delivers.
12. `kenesparta.dev/tf` is deleted and the application repository contains no Terraform.
13. Monthly cost is under $25 as shown in AWS Cost Explorer after a full billing cycle.
14. `free -m` on the host shows swap unused and no container has been OOM-killed (`dmesg | grep -i oom`) after a week
    of normal traffic — the check that AD-1's RAM budget held.
