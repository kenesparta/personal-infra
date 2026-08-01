# 6. Repository Layout

```
personal-infra/
├── README.md
├── Makefile                     # ties the two stages together
├── projects.yml                 # single source of truth, read by both tools
├── .sops.yaml                   # copied from the app repo — same age recipient
├── spec/                        # this document — one file per numbered section
│   ├── README.md                # index + the stable-ID map (C, AD, A, G, Phase)
│   └── NN-<section>.md          # 01-purpose … 14-cost; numbering is what code cites
├── secrets/
│   └── prod.enc.env             # copied, encrypted; committed
├── terraform/
│   ├── versions.tf              # terraform block, provider, backend
│   ├── variables.tf
│   ├── locals.tf                # common_tags, zone_id, projects fan-out
│   ├── main.tf                  # instance, key pair, static IP, firewall
│   ├── dns.tf                   # zones, DNSSEC, KMS
│   ├── dns-records.tf           # Proton mail + Discord records
│   ├── acm.tf                   # certificate + validation
│   ├── cloudfront.tf            # app distribution + apex alias
│   ├── static-cdn.tf            # cdn.kenesparta.dev bucket + distribution
│   ├── iam.tf                   # OIDC provider + CI role
│   ├── legacy.tf                # container service + ECR — DELETED in Phase 7
│   ├── storage.tf               # backup bucket (Phase 3)
│   ├── snapshot-weekly.tf       # EventBridge + Lambda weekly snapshots (§5.8)
│   ├── lambda/                  # weekly_snapshot.py + its generated zip
│   ├── cloudwatch-logs.tf       # log groups + logs-writer IAM user (§5.9)
│   ├── outputs.tf
│   ├── outputs-phase1.tf        # outputs referencing Phase 1+ resources
│   ├── bootstrap.sh             # user_data — minimal, see G4
│   ├── .env                     # gitignored — SSO profile
│   ├── terraform.tfvars         # gitignored
│   └── terraform.tfvars.example
└── ansible/
    ├── ansible.cfg
    ├── site.yml                 # everything except hardening
    ├── harden.yml               # run deliberately, never in site.yml
    ├── inventory/hosts.ini      # generated, gitignored
    ├── group_vars/
    │   ├── all.yml
    │   └── vault.yml            # ansible-vault encrypted
    └── roles/
        ├── common/ docker/ postgres/ caddy/ deploy/ backup/ hardening/
```

Flat within each stage, no Terraform modules and no Ansible collections. Both are premature for a single environment
with one host; introduce them when a second environment exists.
