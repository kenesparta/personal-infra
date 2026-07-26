SHELL := /bin/bash

# Local runs read the SSO profile from terraform/.env (gitignored, see
# terraform/.env.example). CI has no such file and authenticates via OIDC.
-include terraform/.env

# sops' default age key path on macOS differs from the XDG path we use; pin it
# so the sops provider can decrypt secrets/prod.enc.env at plan/apply.
export SOPS_AGE_KEY_FILE ?= $(HOME)/.config/sops/age/keys.txt

TF := terraform -chdir=terraform

# sops operates on one file at a time; override SECRETS_FILE for any other file
# matched by .sops.yaml's path_regex (secrets/*.env).
SOPS_CONFIG  := .sops.yaml
SECRETS_FILE ?= secrets/prod.enc.env

# Only pass -backend-config=profile when a profile is actually set; an empty
# value makes terraform init fail rather than fall through to OIDC creds.
ifneq ($(strip $(TF_VAR_aws_sso_profile)),)
BACKEND_PROFILE := -backend-config="profile=$(TF_VAR_aws_sso_profile)"
endif

.PHONY: help login fmt validate init plan apply state/seed plan/phase0 inventory configure harden check-ssh \
        secrets/show secrets/keys secrets/get secrets/edit secrets/set secrets/unset secrets/check \
        secrets/recipients secrets/recipient-add secrets/recipient-rm secrets/updatekeys secrets/rotate \
        .sops-guard .age-guard

# Groups are the `# ── Title ──` banners below, so section names live in exactly
# one place; a target's help text is the `## …` on its own line.
help: ## Show available targets
	@awk 'BEGIN { FS = ":.*## ?" } \
	      /^# ── / { t = $$0; sub(/^# ── /, "", t); sub(/─.*/, "", t); sub(/ +$$/, "", t); printf "\n%s\n", t; next } \
	      /^[a-zA-Z0-9][a-zA-Z0-9\/_-]*:.*##/ { printf "%-24s%s\n", $$1, $$2 }' $(MAKEFILE_LIST)

# ── Terraform ────────────────────────────────────────────────────────────────

login: ## aws sso login with the profile from terraform/.env
	@test -n "$(TF_VAR_aws_sso_profile)" || { echo "TF_VAR_aws_sso_profile unset; create terraform/.env from .env.example"; exit 1; }
	@aws sso login --profile $(TF_VAR_aws_sso_profile)

fmt: ## terraform fmt
	@$(TF) fmt -recursive

init: ## terraform init against the consolidated backend
	@$(TF) init $(BACKEND_PROFILE)

validate: init ## terraform validate (no credentials required)
	@$(TF) validate

plan: init ## terraform plan
	@$(TF) plan -out=tf.plan

apply: ## terraform apply the saved plan (run `make plan` first)
	@$(TF) apply tf.plan

# ── Phase 0: state consolidation (AD-9) ──────────────────────────────────────

OLD_STATE := s3://tf.kenesparta.dev/dns/prod/kenesparta.dev
NEW_STATE := s3://tf.kenesparta.dev/infra/prod/terraform.tfstate

state/seed: ## Phase 0 step 1 — copy the old state object to the new key (idempotent, non-destructive)
	@echo "  from: $(OLD_STATE)"
	@echo "    to: $(NEW_STATE)"
	@echo "The source object is NEVER modified — it stays as the rollback point (G10)."
	@read -p "Proceed? [y/N] " ok && [ "$$ok" = "y" ]
	@aws s3 cp "$(OLD_STATE)" "$(NEW_STATE)" $(if $(TF_VAR_aws_sso_profile),--profile $(TF_VAR_aws_sso_profile),)

# The gate for the whole migration. Plans the MIGRATED configuration only, with
# the Phase 1 host resources moved aside, so the question it answers is purely
# "did the state copy land correctly?" — uncontaminated by new resources.
# Exit 0 = no changes (pass). Exit 2 = drift (stop and investigate).
plan/phase0: ## Phase 0 step 2 — GATE: must report "No changes"
	@set -e; \
	hold=$$(mktemp -d); \
	trap 'mv "$$hold"/*.tf terraform/ 2>/dev/null || true; rmdir "$$hold" 2>/dev/null || true' EXIT; \
	mv terraform/main.tf terraform/outputs-phase1.tf "$$hold"/; \
	$(TF) init $(BACKEND_PROFILE) >/dev/null; \
	echo "── Phase 0 gate: migrated resources only ──"; \
	$(TF) plan -detailed-exitcode -input=false

# ── Secrets: sops + age ──────────────────────────────────────────────────────
# Reading:  secrets/show | secrets/keys | secrets/get KEY=NAME | secrets/check
# Writing:  secrets/edit | secrets/set KEY=NAME | secrets/unset KEY=NAME
# Keys:     secrets/recipients | secrets/recipient-add AGE=… | secrets/recipient-rm AGE=…
#           then secrets/updatekeys (sync the file to .sops.yaml), secrets/rotate (new data key)
#
# This is the *Terraform* secret mechanism (the sops provider reads
# secrets/prod.enc.env at plan time). Ansible's secrets live in
# ansible/group_vars/vault.yml under ansible-vault — do not conflate them.

.sops-guard:
	@command -v sops >/dev/null || { echo "sops not found — brew install sops"; exit 1; }
	@test -f "$(SECRETS_FILE)" || { echo "no such file: $(SECRETS_FILE)"; exit 1; }

.age-guard:
	@test -f "$(SOPS_AGE_KEY_FILE)" || { echo "no age key at $(SOPS_AGE_KEY_FILE) — see README > Secrets"; exit 1; }

secrets/show: .sops-guard .age-guard ## decrypt SECRETS_FILE to stdout (plaintext! prefer secrets/keys)
	@sops decrypt $(SECRETS_FILE)

secrets/keys: .sops-guard .age-guard ## list the key names only, no values
	@set -o pipefail; sops decrypt $(SECRETS_FILE) | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' | sort

secrets/get: .sops-guard .age-guard ## print one value — make secrets/get KEY=DATABASE_URL
	@test -n "$(KEY)" || { echo "usage: make secrets/get KEY=NAME"; exit 1; }
	@sops decrypt --extract '["$(KEY)"]' $(SECRETS_FILE)

secrets/edit: .sops-guard .age-guard ## open $EDITOR on the decrypted file; re-encrypts on save
	@sops edit $(SECRETS_FILE)

# The value is read from stdin, never from argv — a `make secrets/set KEY=x
# VALUE=y` form would leave the secret in shell history and in `ps` output.
# sops wants JSON, so jq encodes the raw bytes into a JSON string.
secrets/set: .sops-guard .age-guard ## set/replace one key — make secrets/set KEY=NAME (value read from stdin)
	@test -n "$(KEY)" || { echo "usage: make secrets/set KEY=NAME   (value is read from stdin)"; exit 1; }
	@command -v jq >/dev/null || { echo "jq not found — brew install jq"; exit 1; }
	@set -e -o pipefail; \
	 if [ -t 0 ]; then printf 'value for %s (hidden): ' '$(KEY)' >&2; read -rs val; echo >&2; else val=$$(cat); fi; \
	 test -n "$$val" || { echo "empty value, nothing written"; exit 1; }; \
	 printf '%s' "$$val" | jq -Rs . | sops set --value-stdin $(SECRETS_FILE) '["$(KEY)"]'
	@echo "set $(KEY) in $(SECRETS_FILE) — commit the change"

secrets/unset: .sops-guard .age-guard ## remove one key — make secrets/unset KEY=NAME
	@test -n "$(KEY)" || { echo "usage: make secrets/unset KEY=NAME"; exit 1; }
	@sops unset $(SECRETS_FILE) '["$(KEY)"]'
	@echo "removed $(KEY) from $(SECRETS_FILE) — commit the change"

secrets/check: .sops-guard ## verify the file is encrypted and this host can decrypt it (pre-flight for `make plan`)
	@sops filestatus $(SECRETS_FILE)
	@sops decrypt $(SECRETS_FILE) >/dev/null && echo "$(SECRETS_FILE): decryptable with $(SOPS_AGE_KEY_FILE)"

secrets/recipients: ## show .sops.yaml's age recipients and whether the local key is one of them
	@echo "recipients in $(SOPS_CONFIG):"
	@grep -E '^[[:space:]]*age:' $(SOPS_CONFIG) | sed 's/.*age:[[:space:]]*//' | tr ',' '\n' | sed 's/^[[:space:]]*/  /'
	@if [ ! -f "$(SOPS_AGE_KEY_FILE)" ]; then echo "no age key at $(SOPS_AGE_KEY_FILE) — decryption will fail"; \
	 elif ! command -v age-keygen >/dev/null; then echo "(install age to compare against the local key)"; \
	 else echo "local key(s) in $(SOPS_AGE_KEY_FILE):"; \
	   age-keygen -y "$(SOPS_AGE_KEY_FILE)" | while read -r pub; do \
	     if grep -q "$$pub" $(SOPS_CONFIG); then echo "  $$pub  ← listed"; else echo "  $$pub  ← NOT listed"; fi; \
	   done; \
	 fi

# .sops.yaml holds a single inline, comma-separated age list. Anything else
# (several rules, a YAML block list) is refused rather than mangled.
secrets/recipient-add: ## add an age recipient to .sops.yaml — make secrets/recipient-add AGE=age1…
	@set -e; trap 'rm -f $(SOPS_CONFIG).tmp' EXIT; \
	 test -n "$(AGE)" || { echo "usage: make secrets/recipient-add AGE=age1..."; exit 1; }; \
	 [[ "$(AGE)" =~ ^age1[0-9a-z]{58}$$ ]] || { echo "not an age public key: $(AGE)"; exit 1; }; \
	 n=$$(grep -cE '^[[:space:]]*age:' $(SOPS_CONFIG) || true); \
	 test "$$n" = "1" || { echo "$(SOPS_CONFIG) has $$n 'age:' lines — edit it by hand"; exit 1; }; \
	 grep -qE '^[[:space:]]*age:[[:space:]]*age1' $(SOPS_CONFIG) || { echo "'age:' is not an inline recipient list — edit $(SOPS_CONFIG) by hand"; exit 1; }; \
	 if grep -q '$(AGE)' $(SOPS_CONFIG); then echo "$(AGE) is already a recipient"; exit 0; fi; \
	 awk -v k='$(AGE)' '/^[[:space:]]*age:/ { sub(/[[:space:]]+$$/, ""); print $$0 "," k; next } { print }' $(SOPS_CONFIG) > $(SOPS_CONFIG).tmp; \
	 mv $(SOPS_CONFIG).tmp $(SOPS_CONFIG); \
	 echo "added $(AGE) to $(SOPS_CONFIG)"; \
	 echo "now run: make secrets/updatekeys   (existing files stay readable only to the old set until you do)"

secrets/recipient-rm: ## drop an age recipient from .sops.yaml — make secrets/recipient-rm AGE=age1…
	@set -e; trap 'rm -f $(SOPS_CONFIG).tmp' EXIT; \
	 test -n "$(AGE)" || { echo "usage: make secrets/recipient-rm AGE=age1..."; exit 1; }; \
	 grep -q '$(AGE)' $(SOPS_CONFIG) || { echo "$(AGE) is not a recipient"; exit 1; }; \
	 n=$$(grep -E '^[[:space:]]*age:' $(SOPS_CONFIG) | tr ',' '\n' | grep -c 'age1'); \
	 test "$$n" -gt 1 || { echo "refusing: $(AGE) is the only recipient — nothing could encrypt afterwards"; exit 1; }; \
	 awk -v k='$(AGE)' '/^[[:space:]]*age:/ { p=index($$0,"age:"); h=substr($$0,1,p+3); v=substr($$0,p+4); gsub(/[[:space:]]/,"",v); m=split(v,a,","); o=""; for(i=1;i<=m;i++) if(a[i]!=k && a[i]!="") o=(o==""?a[i]:o","a[i]); print h" "o; next } { print }' $(SOPS_CONFIG) > $(SOPS_CONFIG).tmp; \
	 mv $(SOPS_CONFIG).tmp $(SOPS_CONFIG); \
	 echo "removed $(AGE) from $(SOPS_CONFIG)"; \
	 echo "now run: make secrets/updatekeys && make secrets/rotate"; \
	 echo "  updatekeys alone only drops the key from the metadata — the removed holder still knows"; \
	 echo "  the data key of every committed version, so rotate is what actually revokes access."

# Interactive by default: sops prints the +++/--- diff of the key group and
# waits. YES=1 skips the prompt for non-tty callers.
secrets/updatekeys: .sops-guard .age-guard ## re-encrypt the data key for the recipients now in .sops.yaml (YES=1 to skip the prompt)
	@sops updatekeys $(if $(YES),-y,) $(SECRETS_FILE)

secrets/rotate: .sops-guard .age-guard ## new data key + re-encrypt every value (run secrets/updatekeys first if recipients changed)
	@sops rotate -i $(SECRETS_FILE)
	@echo "$(SECRETS_FILE) has a new data key — commit it"

# ── Ansible ──────────────────────────────────────────────────────────────────
# Terraform owns the IP; Ansible reads it rather than duplicating it. NOT a
# local_file resource — that would couple `terraform destroy` to Ansible's tree.
inventory: ## regenerate ansible/inventory/hosts.ini from terraform output
	@printf '[app]\n%s ansible_user=ubuntu\n' "$$($(TF) output -raw static_ip)" > ansible/inventory/hosts.ini
	@cat ansible/inventory/hosts.ini

configure: inventory ## run site.yml (everything except hardening)
	@cd ansible && ansible-playbook -i inventory/hosts.ini site.yml

harden: inventory ## run harden.yml — SNAPSHOT FIRST, see spec A4
	@cd ansible && ansible-playbook -i inventory/hosts.ini harden.yml

check-ssh: inventory ## verify the host accepts an Ansible connection (Phase 2 gate)
	@cd ansible && ansible -i inventory/hosts.ini app -m ping
