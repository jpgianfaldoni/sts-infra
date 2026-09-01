data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  normalized_prefix = trim(replace(lower(var.name_prefix), "_", "-"), "-")
  database_prefix   = replace(local.normalized_prefix, "-", "_")

  bucket_name         = "${substr(local.normalized_prefix, 0, 24)}-glue-${data.aws_caller_identity.current.account_id}-${var.region}"
  database_name       = "${local.database_prefix}_glue_federation"
  table_name          = "sample_orders"
  sample_object_key   = "sample/orders/orders.csv"
  bucket_uri          = "s3://${local.bucket_name}"
  sample_data_uri     = "s3://${local.bucket_name}/sample/orders"
  catalog_storage_uri = "s3://${local.bucket_name}/catalog-metadata"
  sample_schema_json = jsonencode({
    type = "struct"
    fields = [
      {
        name     = "order_id"
        type     = "long"
        nullable = true
        metadata = {}
      },
      {
        name     = "customer"
        type     = "string"
        nullable = true
        metadata = {}
      },
      {
        name     = "region"
        type     = "string"
        nullable = true
        metadata = {}
      },
      {
        name     = "order_date"
        type     = "date"
        nullable = true
        metadata = {}
      },
      {
        name     = "amount"
        type     = "decimal(10,2)"
        nullable = true
        metadata = {}
      },
    ]
  })

  service_role_name = "${local.normalized_prefix}-glue-service"
  storage_role_name = "${local.normalized_prefix}-glue-storage"
  service_role_arn  = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.service_role_name}"
  storage_role_arn  = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.storage_role_name}"

  service_credential_name = "${local.database_prefix}_glue_service_credential"
  storage_credential_name = "${local.database_prefix}_glue_storage_credential"
  external_location_name  = "${local.database_prefix}_glue_external_location"
  connection_name         = "${local.database_prefix}_glue_connection"
  foreign_catalog_name    = "${local.database_prefix}_glue_catalog"

  service_credential_external_id = var.databricks_connectivity_enabled ? databricks_credential.service[0].aws_iam_role[0].external_id : var.service_credential_external_id
  storage_credential_external_id = var.databricks_connectivity_enabled ? databricks_storage_credential.data[0].aws_iam_role[0].external_id : var.storage_credential_external_id
  service_unity_catalog_iam_arn  = var.databricks_connectivity_enabled ? databricks_credential.service[0].aws_iam_role[0].unity_catalog_iam_arn : var.databricks_unity_catalog_iam_arn
  storage_unity_catalog_iam_arn  = var.databricks_connectivity_enabled ? databricks_storage_credential.data[0].aws_iam_role[0].unity_catalog_iam_arn : var.databricks_unity_catalog_iam_arn

  service_trust_principals = concat(
    [local.service_unity_catalog_iam_arn],
    local.service_credential_external_id == "0000" ? [] : [local.service_role_arn],
  )
  storage_trust_principals = concat(
    [local.storage_unity_catalog_iam_arn],
    local.storage_credential_external_id == "0000" ? [] : [local.storage_role_arn],
  )
}

resource "aws_s3_bucket" "this" {
  bucket        = local.bucket_name
  force_destroy = var.force_destroy

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-glue-federation"
  })
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_object" "sample_orders" {
  bucket                 = aws_s3_bucket.this.id
  key                    = local.sample_object_key
  source                 = "${path.module}/assets/sample-orders.csv"
  etag                   = filemd5("${path.module}/assets/sample-orders.csv")
  content_type           = "text/csv"
  server_side_encryption = "AES256"

  depends_on = [
    aws_s3_bucket_ownership_controls.this,
    aws_s3_bucket_public_access_block.this,
    aws_s3_bucket_server_side_encryption_configuration.this,
    aws_s3_bucket_versioning.this,
  ]
}

resource "aws_glue_catalog_database" "this" {
  name        = local.database_name
  description = "Sample database for Databricks AWS Glue Hive metastore federation."
}

resource "aws_glue_catalog_table" "sample_orders" {
  name          = local.table_name
  database_name = aws_glue_catalog_database.this.name
  description   = "Sample CSV orders table for Databricks Glue federation testing."
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL                            = "TRUE"
    classification                      = "csv"
    "skip.header.line.count"            = "1"
    "spark.sql.create.version"          = "3.5.0"
    "spark.sql.sources.provider"        = "csv"
    "spark.sql.sources.schema.numParts" = "1"
    "spark.sql.sources.schema.part.0"   = local.sample_schema_json
    typeOfData                          = "file"
  }

  storage_descriptor {
    location      = local.sample_data_uri
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"
    compressed    = false
    columns {
      name = "order_id"
      type = "bigint"
    }

    columns {
      name = "customer"
      type = "string"
    }

    columns {
      name = "region"
      type = "string"
    }

    columns {
      name = "order_date"
      type = "date"
    }

    columns {
      name = "amount"
      type = "decimal(10,2)"
    }

    ser_de_info {
      name                  = "OpenCSVSerde"
      serialization_library = "org.apache.hadoop.hive.serde2.OpenCSVSerde"

      parameters = {
        separatorChar = ","
        header        = "true"
        path          = local.sample_data_uri
      }
    }
  }

  depends_on = [aws_s3_object.sample_orders]
}

data "aws_iam_policy_document" "service_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = local.service_trust_principals
    }

    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [local.service_credential_external_id]
    }
  }
}

resource "aws_iam_role" "service_credential" {
  name                 = local.service_role_name
  assume_role_policy   = data.aws_iam_policy_document.service_trust.json
  max_session_duration = 3600
  tags                 = var.tags
}

data "aws_iam_policy_document" "service_access" {
  statement {
    sid    = "GrantCatalogAccessToGlue"
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetUserDefinedFunction",
      "glue:GetUserDefinedFunctions",
      "glue:BatchGetPartition",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:glue:${var.region}:${data.aws_caller_identity.current.account_id}:catalog",
      "arn:${data.aws_partition.current.partition}:glue:${var.region}:${data.aws_caller_identity.current.account_id}:database/default",
      aws_glue_catalog_database.this.arn,
      "arn:${data.aws_partition.current.partition}:glue:${var.region}:${data.aws_caller_identity.current.account_id}:table/default/*",
      "arn:${data.aws_partition.current.partition}:glue:${var.region}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.this.name}/*",
      "arn:${data.aws_partition.current.partition}:glue:${var.region}:${data.aws_caller_identity.current.account_id}:userDefinedFunction/default/*",
      "arn:${data.aws_partition.current.partition}:glue:${var.region}:${data.aws_caller_identity.current.account_id}:userDefinedFunction/${aws_glue_catalog_database.this.name}/*",
    ]
  }

  statement {
    sid       = "AllowSelfAssume"
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = [local.service_role_arn]
  }
}

resource "aws_iam_policy" "service_credential" {
  name   = "${local.service_role_name}-policy"
  policy = data.aws_iam_policy_document.service_access.json
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "service_credential" {
  role       = aws_iam_role.service_credential.name
  policy_arn = aws_iam_policy.service_credential.arn
}

data "aws_iam_policy_document" "storage_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = local.storage_trust_principals
    }

    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [local.storage_credential_external_id]
    }
  }
}

resource "aws_iam_role" "storage_credential" {
  name                 = local.storage_role_name
  assume_role_policy   = data.aws_iam_policy_document.storage_trust.json
  max_session_duration = 3600
  tags                 = var.tags
}

data "aws_iam_policy_document" "storage_access" {
  statement {
    sid    = "BucketAccess"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:GetLifecycleConfiguration",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
    ]
    resources = [aws_s3_bucket.this.arn]
  }

  statement {
    sid    = "ObjectAccess"
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:ListMultipartUploadParts",
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.this.arn}/*"]
  }

  statement {
    sid       = "AllowSelfAssume"
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = [local.storage_role_arn]
  }
}

resource "aws_iam_policy" "storage_credential" {
  name   = "${local.storage_role_name}-policy"
  policy = data.aws_iam_policy_document.storage_access.json
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "storage_credential" {
  role       = aws_iam_role.storage_credential.name
  policy_arn = aws_iam_policy.storage_credential.arn
}

resource "time_sleep" "iam_propagation" {
  count = var.databricks_connectivity_enabled ? 1 : 0

  depends_on = [
    aws_iam_role_policy_attachment.service_credential,
    aws_iam_role_policy_attachment.storage_credential,
  ]

  create_duration = "30s"
}
