# ── LEGACY: everything in this file is DESTROYED in Phase 7 ──────────────────
# MIGRATED from kenesparta.dev/tf/lightsail.tf + ecr.tf.
#
# It is here only so the copied state produces a zero-diff plan at Phase 0 and
# so the site keeps serving until the Phase 6 edge cutover. Delete this file in
# Phase 7, after:
#   - Phase 4 has verified the Postgres restore on the host, and
#   - Phase 6 has repointed the CloudFront origin, and
#   - Phase 5 has proved the GHCR pull path.
#
# Deleting it earlier takes the live site down.

# ── Lightsail Container Service (being replaced by the instance) ─────────────

resource "aws_lightsail_container_service" "app" {
  name        = "kenesparta-app"
  power       = "nano" # 0.25 vCPU / 512 MB, ~$7/mo
  scale       = 1
  is_disabled = false

  # ECR image-puller role: lets the service pull the private image.
  # Provider 6.15 can report this update applied without activating the role
  # (state and live service stay is_active=false, principal_arn empty). If
  # that happens, activate it out of band and re-plan:
  #   aws lightsail update-container-service --service-name kenesparta-app \
  #     --private-registry-access '{"ecrImagePullerRole":{"isActive":true}}'
  private_registry_access {
    ecr_image_puller_role {
      is_active = true
    }
  }

  tags = merge(
    local.common_tags,
    {
      Name = "kenesparta-lightsail"
    }
  )
}

# ── Secrets (sops/age) ───────────────────────────────────────────────────────
# secrets/prod.enc.env was COPIED into this repo from kenesparta.dev so this
# path resolves — same age recipient, so it decrypts identically.
#
# Survives Phase 7: the CloudFront origin secret (AD-8) is read from the same
# file. Only the DATABASE_URL consumer below goes away — after Phase 4 the app
# reaches Postgres over 127.0.0.1 and Ansible owns that value.
data "sops_file" "prod_secrets" {
  source_file = "${path.module}/../secrets/prod.enc.env"
  input_type  = "dotenv"
}

resource "aws_lightsail_container_service_deployment_version" "app" {
  service_name = aws_lightsail_container_service.app.name

  # Without this edge Terraform starts the deployment in parallel with the
  # repo policy, and the service tries to pull before it has permission.
  depends_on = [aws_ecr_repository_policy.lightsail_pull]

  container {
    container_name = "app"
    image          = "${aws_ecr_repository.app.repository_url}:${var.image_version}"

    ports = {
      "3000" = "HTTP"
    }

    environment = {
      LEPTOS_SITE_ADDR = "0.0.0.0:3000"
      RUST_LOG         = "info"
      DATABASE_URL     = data.sops_file.prod_secrets.data["DATABASE_URL"]
    }
  }

  public_endpoint {
    container_name = "app"
    container_port = 3000

    health_check {
      healthy_threshold   = 2
      unhealthy_threshold = 5
      timeout_seconds     = 5
      interval_seconds    = 10
      path                = "/"
      success_codes       = "200-399"
    }
  }
}

# ── ECR (replaced by GHCR — AD-10) ───────────────────────────────────────────

resource "aws_ecr_repository" "app" {
  name = "kenespartadev"
  # MUTABLE so CI can move the `latest` alias alongside the vX.Y.Z tags.
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(
    local.common_tags,
    {
      Name = "kenespartadev-ecr"
    }
  )
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "keep only the last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}

resource "aws_ecr_repository_policy" "lightsail_pull" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowLightsailPull"
        Effect = "Allow"
        Principal = {
          AWS = aws_lightsail_container_service.app.private_registry_access[0].ecr_image_puller_role[0].principal_arn
        }
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer"
        ]
      }
    ]
  })
}
