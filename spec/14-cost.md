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
| Route 53 hosted zones (×2)         | $1.00      | $1.00      |
| KMS keys for DNSSEC (×2)           | $2.00      | $2.00      |
| CloudFront (app + cdn)             | ~$1.50     | ~$1.50     |
| S3 (cdn bucket)                    | ~$0.10     | ~$0.10     |
| Static IP (attached)               | —          | $0.00      |
| **Total**                          | **~$27.60**| **~$18.90**|

The migration now **saves ~$8.50/mo** while adding a shell, self-hosted Postgres, and room for several services —
retiring the managed database ($15) more than pays for the instance. Headroom against the $50 ceiling: ~$31, which is
the resize budget: moving to `medium_3_0` later costs $12 more and still lands at ~$31/mo.

If snapshot cost drifts, lower the weekly Lambda's `KEEP` (spec §5.8) before touching anything else. (Under the old
AutoSnapshot add-on this knob did not exist — its seven-copy retention was fixed; that is part of why rev 2.5 replaced
it.)
