resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

resource "aws_s3_bucket" "root" {
  bucket        = "${var.resource_prefix}-workspace-root-${random_string.suffix.result}"
  force_destroy = var.force_destroy_root_bucket
  tags = merge(var.tags, { Name = "${var.resource_prefix}-workspace-root"
  })
}

resource "aws_s3_bucket_ownership_controls" "root" {
  bucket = aws_s3_bucket.root.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_public_access_block" "root" {
  bucket                  = aws_s3_bucket.root.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "root" {
  bucket = aws_s3_bucket.root.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "root" {
  bucket = aws_s3_bucket.root.id
  versioning_configuration {
    status = "Enabled"
  }
}

data "databricks_aws_bucket_policy" "root" {
  provider                 = databricks.mws
  databricks_e2_account_id = var.databricks_account_id
  bucket                   = aws_s3_bucket.root.bucket
}

resource "aws_s3_bucket_policy" "root" {
  bucket = aws_s3_bucket.root.id
  policy = data.databricks_aws_bucket_policy.root.json

  depends_on = [
    aws_s3_bucket_ownership_controls.root,
    aws_s3_bucket_public_access_block.root,
  ]

  lifecycle {
    ignore_changes = [policy]
  }
}
