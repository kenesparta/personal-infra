# 14. Cost Model

| Line item                          | Current    | Target     |
|------------------------------------|------------|------------|
| Lightsail Container Service (nano) | $7.00      | —          |
| Lightsail Small instance           | —          | $12.00     |
| Lightsail managed PostgreSQL       | ~$15.00    | —          |
| Auto-snapshots (60 GB, incremental)| —          | ~$1.50     |
| Backup bucket (5 GB)               | —          | $1.00      |
| ECR storage (last 10 images)       | ~$1.00     | —          |
| Route 53 hosted zones (×2)         | $1.00      | $1.00      |
| KMS keys for DNSSEC (×2)           | $2.00      | $2.00      |
| CloudFront (app + cdn)             | ~$1.50     | ~$1.50     |
| S3 (cdn bucket)                    | ~$0.10     | ~$0.10     |
| Static IP (attached)               | —          | $0.00      |
| **Total**                          | **~$27.60**| **~$19.10**|

The migration now **saves ~$8.50/mo** while adding a shell, self-hosted Postgres, and room for several services —
retiring the managed database ($15) more than pays for the instance. Headroom against the $50 ceiling: ~$31, which is
the resize budget: moving to `medium_3_0` later costs $12 more and still lands at ~$31/mo.

If snapshot cost drifts, reduce the retained count before touching anything else.
