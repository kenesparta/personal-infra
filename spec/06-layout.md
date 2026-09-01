# 6. Repository Layout

```
personal-infra/
├── README.md
├── SECURITY.md                  # OS patch posture: what is automatic, what is not (§9.7)
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
│   ├── dns.tf                   # kenesparta.dev + kecc.link zones, DNSSEC, KMS
│   ├── dns-records.tf           # Proton mail + Discord records
│   ├── acm.tf                   # kenesparta.dev certificate + validation
│   ├── dns-auruming.tf          # auruming.com zone, DNSSEC, KMS (§5.12)
│   ├── acm-auruming.tf          # auruming.com certificate + validation (§5.12)
│   ├── static-cdn-auruming.tf   # cdn.auruming.com asset bucket + distribution (§5.13)
│   ├── cloudfront.tf            # app distribution + apex alias
│   ├── static-cdn.tf            # cdn.kenesparta.dev bucket + distribution
│   ├── static-cnayp-bot.tf      # cnayp-bot.kenesparta.dev legal pages (§5.11)
│   ├── status-pages.tf          # kenesparta.dev origin-failure pages: bucket, OAC (§5.15)
│   ├── status-pages-auruming.tf # auruming.com's own status bucket (§5.15)
│   ├── status-pages/            # the HTML itself, one directory per public hostname
│   ├── iam.tf                   # OIDC provider + CI roles
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
    ├── security.yml             # OS security updates: report, and apply on request (§9.7)
    ├── inventory/hosts.ini      # generated, gitignored
    ├── group_vars/
    │   ├── all.yml
    │   └── vault.yml            # ansible-vault encrypted
    └── roles/
        ├── common/ docker/ postgres/ caddy/ deploy/ backup/ hardening/
```

Flat within each stage, no Terraform modules and no Ansible collections. Both are premature for a single environment
with one host; introduce them when a second environment exists.

*Rev 2.12:* a second **registered domain** is not a second environment. `auruming.com` gets its own pair of files
rather than a module, for the same reason: one host, one state, one environment. The `-auruming` suffix is the
convention for any further domain — a diff that touches only `*-auruming.tf` is visibly not touching the zone that
carries mail (G10).
