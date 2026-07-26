# 13. Out of Scope

| Item                                    | Reconsider when                                                                    |
|-----------------------------------------|------------------------------------------------------------------------------------|
| Multi-instance / HA                     | Downtime becomes unacceptable — note this requires an ALB and doubles compute cost |
| Managed database                        | Backup discipline proves unsustainable in practice                                 |
| CloudFront origin lockdown by network   | Migrating to EC2 (G11)                                                             |
| Terraform modules / Ansible collections | A second environment (staging) exists                                              |
| Ansible for app deployment              | Never — the systemd timer owns this (A5)                                           |
| Autoscaling                             | Sustained traffic exceeds ~100 req/s                                               |
| CI/CD pipeline definition               | Belongs in each application repository                                             |
