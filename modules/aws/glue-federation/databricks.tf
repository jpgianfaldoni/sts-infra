resource "terraform_data" "metastore_assignment" {
  count = var.databricks_connectivity_enabled ? 1 : 0
  input = var.databricks_metastore_assignment_id

  lifecycle {
    precondition {
      condition     = var.databricks_metastore_assignment_id != null
      error_message = "databricks_metastore_assignment_id is required when Databricks connectivity is enabled."
    }
  }
}

resource "databricks_credential" "service" {
  count    = var.databricks_connectivity_enabled ? 1 : 0
  provider = databricks.workspace

  name            = local.service_credential_name
  purpose         = "SERVICE"
  comment         = "Terraform-managed service credential for AWS Glue federation."
  skip_validation = true
  force_destroy   = var.force_destroy

  aws_iam_role {
    role_arn = local.service_role_arn
  }

  depends_on = [terraform_data.metastore_assignment]
}

resource "databricks_storage_credential" "data" {
  count    = var.databricks_connectivity_enabled ? 1 : 0
  provider = databricks.workspace

  name            = local.storage_credential_name
  comment         = "Terraform-managed storage credential for AWS Glue federation data."
  skip_validation = true
  force_destroy   = var.force_destroy
  force_update    = var.force_destroy

  aws_iam_role {
    role_arn = local.storage_role_arn
  }

  depends_on = [terraform_data.metastore_assignment]
}

resource "databricks_external_location" "data" {
  count    = var.databricks_connectivity_enabled ? 1 : 0
  provider = databricks.workspace

  name            = local.external_location_name
  url             = local.bucket_uri
  credential_name = databricks_storage_credential.data[0].name
  comment         = "Terraform-managed external location for AWS Glue federation data."
  force_destroy   = var.force_destroy

  depends_on = [
    aws_s3_bucket_ownership_controls.this,
    aws_s3_bucket_public_access_block.this,
    aws_s3_bucket_server_side_encryption_configuration.this,
    aws_s3_bucket_versioning.this,
    time_sleep.iam_propagation,
  ]
}

resource "databricks_connection" "glue" {
  count    = var.databricks_connectivity_enabled ? 1 : 0
  provider = databricks.workspace

  name            = local.connection_name
  connection_type = "GLUE"
  comment         = "Terraform-managed connection to the AWS Glue Data Catalog."
  options = {
    aws_region     = var.region
    aws_account_id = data.aws_caller_identity.current.account_id
    credential     = databricks_credential.service[0].name
  }

  depends_on = [time_sleep.iam_propagation]
}

resource "databricks_catalog" "glue" {
  count    = var.databricks_connectivity_enabled ? 1 : 0
  provider = databricks.workspace

  name            = local.foreign_catalog_name
  connection_name = databricks_connection.glue[0].name
  comment         = "Terraform-managed foreign catalog backed by AWS Glue."
  options = {
    authorized_paths = local.bucket_uri
    storage_root     = local.catalog_storage_uri
  }
  force_destroy = var.force_destroy

  depends_on = [databricks_external_location.data]
}
