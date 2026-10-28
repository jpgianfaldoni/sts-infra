data "aws_caller_identity" "current" {
}

resource "random_string" "suffix" {
  count   = var.create_initial_catalog ? 1 : 0
  length  = 8
  upper   = false
  special = false
}

locals {
  role_name              = "${var.resource_prefix}-uc-storage"
  bucket_name            = var.create_initial_catalog ? "${var.resource_prefix}-uc-${random_string.suffix[0].result}" : null
  managed_metastore_name = "${var.resource_prefix}-metastore"
}

data "databricks_metastore" "existing" {
  count    = var.metastore_mode == "existing" ? 1 : 0
  provider = databricks.mws
  name     = var.existing_metastore_name

  lifecycle {
    precondition {
      condition     = var.existing_metastore_name != null
      error_message = "metastore_mode = existing requires existing_metastore_name."
    }
  }
}

# Auto mode lists the account's metastores. It keeps managing the metastore it
# created earlier (matched by name, so later plans do not flip), reuses the only
# other metastore in this region, or creates one when the region has none.
# Shared accounts can hold many metastores per region; auto mode refuses to
# guess between them.
data "databricks_metastores" "all" {
  count    = var.metastore_mode == "auto" ? 1 : 0
  provider = databricks.mws
}

data "databricks_metastore" "candidate" {
  for_each = var.metastore_mode == "auto" ? {
    for name, id in data.databricks_metastores.all[0].ids : name => id
    if name != local.managed_metastore_name
  } : {}
  provider     = databricks.mws
  metastore_id = each.value
}

locals {
  regional_metastores = {
    for name, metastore in data.databricks_metastore.candidate :
    name => try(metastore.metastore_info[0].metastore_id, metastore.metastore_id, metastore.id)
    if try(metastore.metastore_info[0].region, metastore.region, null) == var.region
  }
  managed_metastore_exists = var.metastore_mode == "auto" && contains(keys(try(data.databricks_metastores.all[0].ids, {})), local.managed_metastore_name)
  auto_metastore_ambiguous = var.metastore_mode == "auto" && !local.managed_metastore_exists && length(local.regional_metastores) > 1
  reused_metastore_id = (
    var.metastore_mode == "auto" && !local.managed_metastore_exists && length(local.regional_metastores) == 1
    ? one(values(local.regional_metastores)) : null
  )
  create_metastore = var.metastore_mode == "create" || (var.metastore_mode == "auto" && local.reused_metastore_id == null)
  metastore_id = local.create_metastore ? databricks_metastore.this[0].id : (
    var.metastore_mode == "auto" ? local.reused_metastore_id : data.databricks_metastore.existing[0].id
  )
}

resource "databricks_metastore" "this" {
  count         = local.create_metastore ? 1 : 0
  provider      = databricks.mws
  name          = local.managed_metastore_name
  region        = var.region
  force_destroy = var.force_destroy
}

resource "databricks_metastore_assignment" "this" {
  provider     = databricks.mws
  workspace_id = var.workspace_id
  metastore_id = local.metastore_id
}

resource "aws_s3_bucket" "catalog" {
  count         = var.create_initial_catalog ? 1 : 0
  bucket        = local.bucket_name
  force_destroy = var.force_destroy
  tags = merge(var.tags, { Name = "${var.resource_prefix}-uc"
  })
}

resource "aws_s3_bucket_ownership_controls" "catalog" {
  count  = var.create_initial_catalog ? 1 : 0
  bucket = aws_s3_bucket.catalog[0].id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_public_access_block" "catalog" {
  count                   = var.create_initial_catalog ? 1 : 0
  bucket                  = aws_s3_bucket.catalog[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "catalog" {
  count  = var.create_initial_catalog ? 1 : 0
  bucket = aws_s3_bucket.catalog[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "catalog" {
  count  = var.create_initial_catalog ? 1 : 0
  bucket = aws_s3_bucket.catalog[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

data "databricks_aws_unity_catalog_policy" "catalog" {
  count          = var.create_initial_catalog ? 1 : 0
  provider       = databricks.mws
  aws_account_id = data.aws_caller_identity.current.account_id
  bucket_name    = aws_s3_bucket.catalog[0].bucket
  role_name      = local.role_name
}

data "databricks_aws_unity_catalog_assume_role_policy" "catalog" {
  count          = var.create_initial_catalog ? 1 : 0
  provider       = databricks.mws
  aws_account_id = data.aws_caller_identity.current.account_id
  role_name      = local.role_name
  external_id    = var.databricks_account_id
}

resource "aws_iam_role" "catalog" {
  count              = var.create_initial_catalog ? 1 : 0
  name               = local.role_name
  assume_role_policy = data.databricks_aws_unity_catalog_assume_role_policy.catalog[0].json
  tags               = var.tags
}

resource "aws_iam_policy" "catalog" {
  count  = var.create_initial_catalog ? 1 : 0
  name   = local.role_name
  policy = data.databricks_aws_unity_catalog_policy.catalog[0].json
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "catalog" {
  count      = var.create_initial_catalog ? 1 : 0
  role       = aws_iam_role.catalog[0].name
  policy_arn = aws_iam_policy.catalog[0].arn
}

resource "time_sleep" "iam" {
  count           = var.create_initial_catalog ? 1 : 0
  depends_on      = [aws_iam_role_policy_attachment.catalog]
  create_duration = "30s"
}

resource "databricks_storage_credential" "catalog" {
  count         = var.create_initial_catalog ? 1 : 0
  provider      = databricks.workspace
  name          = local.role_name
  metastore_id  = local.metastore_id
  comment       = "Terraform-managed credential for the initial catalog."
  force_destroy = var.force_destroy
  force_update  = var.force_destroy
  aws_iam_role {
    role_arn = aws_iam_role.catalog[0].arn
  }
  depends_on = [databricks_metastore_assignment.this, time_sleep.iam]
}

resource "databricks_external_location" "catalog" {
  count           = var.create_initial_catalog ? 1 : 0
  provider        = databricks.workspace
  name            = "${var.resource_prefix}-catalog-location"
  url             = "s3://${aws_s3_bucket.catalog[0].bucket}"
  credential_name = databricks_storage_credential.catalog[0].name
  force_destroy   = var.force_destroy
  depends_on = [
    aws_s3_bucket_ownership_controls.catalog,
    aws_s3_bucket_public_access_block.catalog,
    aws_s3_bucket_server_side_encryption_configuration.catalog,
    aws_s3_bucket_versioning.catalog,
  ]
}

resource "databricks_catalog" "initial" {
  count         = var.create_initial_catalog ? 1 : 0
  provider      = databricks.workspace
  name          = var.catalog_name
  storage_root  = "${trimsuffix(databricks_external_location.catalog[0].url, "/")}/${var.catalog_name}"
  comment       = "Initial Terraform-managed catalog."
  force_destroy = var.force_destroy
}
