# ---------------------------------------------------------------------------
# Database backups
#
# A CronJob in the cluster runs pg_dump and writes to this bucket using IRSA.
# Backups you have never restored are not backups, so `ansible/ops/restore-db.yml`
# exists and docs/RUNBOOK.md covers the restore path.
#
# Cost: a few cents. The lifecycle rule below stops an untended lab from
# accumulating dumps forever.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "backups" {
  bucket = "${var.name}-backups-${data.aws_caller_identity.current.account_id}"

  # Lab convenience: lets `terraform destroy` remove the bucket with objects
  # still in it. NEVER set this on a real backup bucket.
  force_destroy = true

  tags = { Name = "${var.name}-backups" }
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "expire-old-backups"
    status = "Enabled"

    filter {}

    expiration {
      days = var.backup_retention_days
    }

    # Versioning is on, so non-current versions must be expired separately or
    # they accumulate invisibly and keep billing.
    noncurrent_version_expiration {
      noncurrent_days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# --- IRSA for the backup CronJob --------------------------------------------

data "aws_iam_policy_document" "backup_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:l2lab:backup"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = "${var.name}-backup"
  assume_role_policy = data.aws_iam_policy_document.backup_assume.json
  tags               = { Name = "${var.name}-backup" }
}

data "aws_iam_policy_document" "backup" {
  # Write and read objects, scoped to this bucket only.
  statement {
    actions   = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"]
    resources = ["${aws_s3_bucket.backups.arn}/*"]
  }

  # Listing is a bucket-level action, so it needs the bucket ARN, not /*.
  # Getting this wrong is the single most common S3 IAM mistake.
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.backups.arn]
  }

  # The CronJob also needs the database password to run pg_dump.
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [aws_secretsmanager_secret.postgres.arn]
  }
}

resource "aws_iam_role_policy" "backup" {
  name   = "backup-to-s3"
  role   = aws_iam_role.backup.id
  policy = data.aws_iam_policy_document.backup.json
}

output "backup_bucket" { value = aws_s3_bucket.backups.id }
output "backup_role_arn" { value = aws_iam_role.backup.arn }
