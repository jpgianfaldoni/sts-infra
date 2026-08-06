data "aws_caller_identity" "current" {
}

resource "random_string" "suffix" {
  length  = 8
  upper   = false
  special = false
}

locals {
  role_name   = "${var.resource_prefix}-uc-storage"
  bucket_name = "${var.resource_prefix}-uc-${random_string.suffix.result}"
}

resource "databricks_metastore" "this" {
  provider      = databricks.mws
  name          = "${var.resource_prefix}-metastore"
  region        = var.region
  force_destroy = var.force_destroy
}

resource "databricks_metastore_assignment" "this" {
  provider     = databricks.mws
  workspace_id = var.workspace_id
  metastore_id = databricks_metastore.this.id
}

resource "aws_s3_bucket" "catalog" {
  bucket        = local.bucket_name
  force_destroy = var.force_destroy
  tags = merge(var.tags, { Name = "${var.resource_prefix}-uc"
  })
}

resource "aws_s3_bucket_ownership_controls" "catalog" {
  bucket = aws_s3_bucket.catalog.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_public_access_block" "catalog" {
  bucket                  = aws_s3_bucket.catalog.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "catalog" {
  bucket = aws_s3_bucket.catalog.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "catalog" {
  bucket = aws_s3_bucket.catalog.id
  versioning_configuration {
    status = "Enabled"
  }
}

data "databricks_aws_unity_catalog_policy" "catalog" {
  provider       = databricks.mws
  aws_account_id = data.aws_caller_identity.current.account_id
  bucket_name    = aws_s3_bucket.catalog.bucket
  role_name      = local.role_name
}

data "databricks_aws_unity_catalog_assume_role_policy" "catalog" {
  provider       = databricks.mws
  aws_account_id = data.aws_caller_identity.current.account_id
  role_name      = local.role_name
  external_id    = var.databricks_account_id
}

resource "aws_iam_role" "catalog" {
  name               = local.role_name
  assume_role_policy = data.databricks_aws_unity_catalog_assume_role_policy.catalog.json
  tags               = var.tags
}

resource "aws_iam_policy" "catalog" {
  name   = local.role_name
  policy = data.databricks_aws_unity_catalog_policy.catalog.json
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "catalog" {
  role       = aws_iam_role.catalog.name
  policy_arn = aws_iam_policy.catalog.arn
}

resource "time_sleep" "iam" {
  depends_on      = [aws_iam_role_policy_attachment.catalog]
  create_duration = "30s"
}

resource "databricks_storage_credential" "catalog" {
  provider      = databricks.workspace
  name          = local.role_name
  metastore_id  = databricks_metastore.this.id
  comment       = "Terraform-managed credential for the initial catalog."
  force_destroy = var.force_destroy
  force_update  = var.force_destroy
  aws_iam_role {
    role_arn = aws_iam_role.catalog.arn
  }
  depends_on = [databricks_metastore_assignment.this, time_sleep.iam]
}

resource "databricks_external_location" "catalog" {
  provider        = databricks.workspace
  name            = "${var.resource_prefix}-catalog-location"
  url             = "s3://${aws_s3_bucket.catalog.bucket}"
  credential_name = databricks_storage_credential.catalog.name
  force_destroy   = var.force_destroy
  depends_on = [
    aws_s3_bucket_ownership_controls.catalog,
    aws_s3_bucket_public_access_block.catalog,
    aws_s3_bucket_server_side_encryption_configuration.catalog,
    aws_s3_bucket_versioning.catalog,
  ]
}

resource "databricks_catalog" "initial" {
  provider      = databricks.workspace
  name          = var.catalog_name
  storage_root  = "${trimsuffix(databricks_external_location.catalog.url, "/")}/${var.catalog_name}"
  comment       = "Initial Terraform-managed catalog."
  force_destroy = var.force_destroy
}
