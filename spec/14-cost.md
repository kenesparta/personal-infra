# 14. Cost Model

| Line item                          | Current    | Target     |
|------------------------------------|------------|------------|
| Lightsail Container Service (nano) | $7.00      | —          |
| Lightsail Small instance           | —          | $12.00     |
| Lightsail managed PostgreSQL       | ~$15.00    | —          |
| Snapshots (4 weekly, incremental)  | —          | ~$1.20     |
| Backup bucket (5 GB)               | —          | $1.00      |
| CloudWatch Logs (7-day retention)  | —          | ~$0.10     |
| ECR storage (last 10 images)       | ~$1.00     | —          |
| Route 53 hosted zones (×3)         | $1.00      | $1.50      |
| KMS keys for DNSSEC (×3)           | $2.00      | $3.00      |
| CloudFront (app + cdn + per-project)| ~$1.50     | ~$1.50     |
| S3 (cdn buckets)                   | ~$0.10     | ~$0.15     |
| Static IP (attached)               | —          | $0.00      |
| **Total**                          | **~$27.60**| **~$20.40**|

The migration now **saves ~$7/mo** while adding a shell, self-hosted Postgres, and room for several services —
retiring the managed database ($15) more than pays for the instance. Headroom against the $50 ceiling: ~$29.60, which
is the resize budget: moving to `medium_3_0` later costs $12 more and still lands at ~$32.40/mo.

*Rev 2.12:* `auruming.com` adds **$1.50/mo** and nothing else — a hosted zone ($0.50) and its DNSSEC KMS key ($1.00).
Its CloudFront distribution, its ACM certificate and its Let's Encrypt certificate are all free, and it consumes RAM
and disk already paid for on the instance. A second registered domain is, at this scale, the cheapest thing in the
estate; the counters that would actually move are CloudFront requests and CloudWatch ingest, both traffic-driven
(C2).

If snapshot cost drifts, lower the weekly Lambda's `KEEP` (spec §5.8) before touching anything else. (Under the old
AutoSnapshot add-on this knob did not exist — its seven-copy retention was fixed; that is part of why rev 2.5 replaced
it.)
