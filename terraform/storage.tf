# ── PHASE 3: off-host database backups (spec §5.7) ───────────────────────────
# Destination for the pg_dump timer installed by the Ansible `backup` role.
# Additive, like main.tf — `make plan/phase0` moves this file aside so the
# Phase 0 gate keeps answering only "did the state copy land correctly?".

resource "aws_lightsail_bucket" "backups" {
  name = var.backup_bucket_name

  # small_1_0 = 5 GB, $1/mo — the line item already in spec §14. Verify with:
  #   aws lightsail get-bucket-bundles
  # The bundle can be raised later but never lowered.
  bundle_id = "small_1_0"

  tags = merge(
    local.common_tags,
    {
      Name = var.backup_bucket_name
    }
  )
}

# Versioning is deliberately absent: aws_lightsail_bucket exposes no versioning
# argument (checked against provider 6.15.0 — the schema is
# name/bundle_id/force_delete/tags and nothing else). Rather than manage it out
# of band, the backup script writes a TIMESTAMPED key per run, so a dump is
# never overwritten and there is nothing for versioning to protect. Lightsail
# buckets also have no lifecycle rules, so nothing expires on its own: the
# script prunes only its local copies, and remote pruning stays a deliberate
# manual act (spec §5.7).

# ── Resource access: the instance reaches the bucket with NO credential ──────
# This is the Lightsail-native equivalent of an EC2 instance profile, and it is
# why no access key exists anywhere in this repository. AWS:
#
#   "Use resource access to grant full read and write access to a bucket and
#    its objects for Lightsail instances. With resource access, you don't have
#    to manage credentials like access keys."
#
# Attaching the instance makes the AWS CLI on the box resolve credentials from
# instance metadata automatically, so `aws s3 cp` in pg-backup.sh just works.
# Detaching revokes access immediately — there is no key to rotate, leak, or
# forget to remove, and nothing sensitive lands in Terraform state.
#
# This does NOT generalise. It is scoped to Lightsail BUCKETS; the box still
# cannot assume a role for any other AWS API, which is why AD-10 (GHCR over
# ECR) is unaffected — there is no equivalent attachment for ECR. See G5.
resource "aws_lightsail_bucket_resource_access" "backups_host" {
  bucket_name   = aws_lightsail_bucket.backups.name
  resource_name = aws_lightsail_instance.app.name
}
