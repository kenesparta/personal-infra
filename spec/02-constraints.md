# 2. Constraints

These are fixed inputs, not preferences to be optimized away.

| #   | Constraint                                            | Implication                                              |
|-----|-------------------------------------------------------|----------------------------------------------------------|
| C1  | Budget ceiling **$50/month**, target ~$20             | No load balancer, no NAT gateway, no managed database    |
| C2  | Peak traffic **≤10 req/s**, low concurrency           | Single instance is sufficient; no autoscaling            |
| C3  | **Up to 4 services**, all Rust, all containerized     | Shared host, shared proxy, shared Postgres; fits 2 GB with headroom — see AD-1 |
| C4  | **CloudFront stays** at the edge; no third-party CDN  | TLS terminates twice — ACM at CloudFront, LE on the host |
| C5  | **No ECS / no orchestrator**                          | Docker Compose + systemd                                 |
| C6  | **No self-hosted CI runner** on the instance          | Deploys are pull-based                                   |
| C7  | **No ECR** — images come from GHCR                    | Instance cannot assume an IAM role; see AD-10            |
| C8  | Personal projects; brief downtime acceptable          | Single point of failure is an accepted risk              |
| C9  | **Route 53 zones and DNSSEC must survive** the move   | No zone is ever destroyed and recreated; see G10         |
| C10 | `kenesparta.dev/tf` is **retired**, not run in parallel | One state owns the account after cutover; see AD-9      |
