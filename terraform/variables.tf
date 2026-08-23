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

# ── Second registered domain (rev 2.12, AD-13) ───────────────────────────────
# NOT a subdomain of primary_dns and not a tag value — this is a key in
# local.domains, matched verbatim against `domain:` in projects.yml. Changing it
# without changing that file breaks the lookup at plan time (loudly, which is
# the intent — G24).
#
# Registered at NAMECHEAP, not Route 53. Terraform creates and signs the zone;
# the nameserver delegation and the DNSSEC DS record are pasted into the
# registrar by hand, in the order G23 gives, and nothing here can tell whether
# that has been done.
variable "auruming_dns" {
  type    = string
  default = "auruming.com"
}

# Static asset CDN for auruming.com (§5.13). Deliberately NOT dotted: a name
# like "cdn.auruming.com" puts extra labels into the S3 REST endpoint, where
# the *.s3.<region>.amazonaws.com certificate covers only one. Nobody sees this
# name — the public one is the CloudFront alias.
variable "auruming_cdn_bucket_name" {
  description = "S3 bucket behind cdn.auruming.com. Globally unique across all of S3; change if the default is taken."
  type        = string
  default     = "auruming-cdn"

  validation {
    # Same rule as backup_bucket_name: lowercase alphanumeric and hyphens, no
    # dots, start and end alphanumeric.
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.auruming_cdn_bucket_name))
    error_message = "auruming_cdn_bucket_name must be lowercase alphanumeric or hyphen, starting and ending alphanumeric, and must contain no dots (§5.13)."
  }
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
