############################################
# S3: Storage (corp.doc) and Backup Storage (dmz.doc)
############################################
locals {
  buckets = {
    storage = "${local.name}-corp-storage-${local.account_id}"
    backup  = "${local.name}-dmz-backup-${local.account_id}"
  }
}

resource "aws_s3_bucket" "this" {
  for_each = local.buckets

  bucket = each.value
  tags   = { Name = each.value }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = aws_s3_bucket.this

  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

data "aws_iam_policy_document" "bucket_tls_only" {
  for_each = aws_s3_bucket.this

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      each.value.arn,
      "${each.value.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  for_each = aws_s3_bucket.this

  bucket     = each.value.id
  policy     = data.aws_iam_policy_document.bucket_tls_only[each.key].json
  depends_on = [aws_s3_bucket_public_access_block.this]
}

resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket = aws_s3_bucket.this["backup"].id

  rule {
    id     = "tier-and-expire"
    status = "Enabled"

    filter {
      prefix = ""
    }

    transition {
      days          = 30
      storage_class = "GLACIER_IR"
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

############################################
# PII Database (RDS PostgreSQL) - isolated subnets, no internet route
############################################
resource "aws_db_subnet_group" "pii" {
  name       = "${local.name}-pii"
  subnet_ids = [aws_subnet.this["dmz_data_a"].id, aws_subnet.this["dmz_data_b"].id]
}

resource "aws_db_instance" "pii" {
  identifier     = "${local.name}-pii"
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name                             = var.db_name
  username                            = var.db_username
  manage_master_user_password         = true # password lives in Secrets Manager
  iam_database_authentication_enabled = true

  db_subnet_group_name   = aws_db_subnet_group.pii.name
  vpc_security_group_ids = [aws_security_group.this["rds"].id]
  publicly_accessible    = false
  multi_az               = var.db_multi_az && !var.lite_mode # Multi-AZ is not free-tier eligible

  backup_retention_period         = var.lite_mode ? 1 : 7 # Free plan caps automated backup retention
  copy_tags_to_snapshot           = true
  enabled_cloudwatch_logs_exports = ["postgresql"]
  auto_minor_version_upgrade      = true

  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.name}-pii-final"

  tags = { Name = "${local.name}-pii", Domain = "dmz.doc", DataClass = "PII" }
}
