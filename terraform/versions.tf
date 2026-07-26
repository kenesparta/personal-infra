terraform {
  # >= 1.10 for native S3 state locking (use_lockfile); no DynamoDB table.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Pinned to the exact version the migrated state was written by. Spec
      # §5.1 allows "~> 6.0", but Phase 0's gate is a plan with ZERO changes,
      # and a provider minor bump can surface schema drift as spurious diffs.
      # Loosen this only after Phase 0 has passed.
      version = "6.15.0"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.2"
    }
  }

  # Seeded by copying the old state object (AD-9), NOT by import blocks:
  #   aws s3 cp s3://tf.kenesparta.dev/dns/prod/kenesparta.dev \
  #             s3://tf.kenesparta.dev/infra/prod/terraform.tfstate
  # The old key is left in place untouched as the rollback point.
  backend "s3" {
    bucket       = "tf.kenesparta.dev"
    key          = "infra/prod/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

# Rev 1 specified a second provider aliased to us-east-1 for Lightsail DNS
# zones. That alias is GONE: DNS is Route 53 (global) and the account already
# operates in us-east-1.
provider "aws" {
  # Local runs use the SSO profile (terraform/.env); CI leaves it empty and
  # authenticates with the OIDC role's env credentials.
  profile = var.aws_sso_profile != "" ? var.aws_sso_profile : null
  region  = var.region
}

# Decrypts ../secrets/prod.enc.env with the age key: locally via
# SOPS_AGE_KEY_FILE (exported by the Makefile), in CI via the SOPS_AGE_KEY
# repo secret.
provider "sops" {}
