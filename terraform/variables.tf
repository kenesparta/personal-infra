# ── Migrated variables ───────────────────────────────────────────────────────
# `project`, `owner` and `environment` feed local.common_tags, which is written
# into the tags of every migrated resource and therefore lives in state.
# CHANGING THEIR DEFAULTS PRODUCES A DIFF ON EVERY TAGGED RESOURCE. Leave them.

variable "aws_sso_profile" {
  description = "AWS SSO profile for local runs (terraform/.env). Empty in CI, where credentials come from the OIDC role."
  type        = string
  default     = ""
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  description = "Tag value only. Historical name; do not 'fix' it — see the note above."
  type        = string
  default     = "dns"
}

variable "owner" {
  type    = string
  default = "kenesparta"
}

variable "environment" {
  description = "The type of deployment environment. Must be one of 'dev', or 'prod'."
  type        = string
  default     = "prod"
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "The 'environment' must be one of 'dev' or 'prod'."
  }
}

variable "primary_dns" {
  type    = string
  default = "kenesparta.dev"
}

variable "link_dns" {
  type    = string
  default = "kecc.link"
}

variable "image_version" {
  description = "LEGACY (destroyed in Phase 7): tag of the backend image in ECR for the Lightsail container service."
  type        = string
  default     = "latest"
}

# ── Instance (Phase 1) ───────────────────────────────────────────────────────

variable "instance_name" {
  description = "Lightsail INSTANCE name. Deliberately not 'kenesparta-app' — the container service holds that name and both coexist until Phase 7."
  type        = string
  default     = "kenesparta-host"
}

variable "availability_zone" {
  description = "Lightsail supports only a subset of AZs per region (G1). Verify with `aws lightsail get-regions --include-availability-zones`."
  type        = string
  default     = "us-east-1a"
}

variable "blueprint_id" {
  description = "Verify with `aws lightsail get-blueprints` — IDs change over time."
  type        = string
  default     = "ubuntu_24_04"
}

variable "bundle_id" {
  description = "small_3_0 = 2 GB / 2 vCPU / 60 GB / 3 TB, $12/mo. RAM is the binding constraint at four services (AD-1)."
  type        = string
  default     = "small_3_0"
}

variable "ssh_public_key_path" {
  description = "Path to the public key authorized on the instance. Read with file(pathexpand(...)) because tfvars cannot call functions."
  type        = string
  default     = "~/.ssh/personal-infra.pub"
}

# ── Backups (Phase 3) ────────────────────────────────────────────────────────

variable "backup_bucket_name" {
  description = "Lightsail bucket for pg_dump artifacts. Globally unique across all Lightsail accounts; change if the default is taken. Lowercase letters, digits and hyphens only — no dots."
  type        = string
  default     = "kenesparta-infra-backups"

  validation {
    # Lightsail bucket naming: 3–54 chars, lowercase alphanumeric and hyphens,
    # must start and end alphanumeric. Dots are rejected (unlike plain S3).
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,52}[a-z0-9]$", var.backup_bucket_name))
    error_message = "backup_bucket_name must be 3-54 chars, lowercase alphanumeric or hyphen, starting and ending alphanumeric."
  }
}

variable "ssh_allowed_cidrs" {
  description = "Source CIDRs permitted on port 22. Home/office IPs only."
  type        = list(string)

  validation {
    # Spec §5.5 and acceptance criterion 6. The firewall resource is
    # authoritative (G3), so a wildcard here silently exposes SSH globally.
    condition     = !contains(var.ssh_allowed_cidrs, "0.0.0.0/0")
    error_message = "ssh_allowed_cidrs must never contain 0.0.0.0/0 (spec §5.5)."
  }

  validation {
    condition     = length(var.ssh_allowed_cidrs) > 0
    error_message = "ssh_allowed_cidrs must list at least one CIDR, or SSH is unreachable."
  }
}
