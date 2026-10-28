variable "databricks_account_id" {
  type = string
}
variable "workspace_id" {
  type = number
}
variable "region" {
  type = string
}
variable "resource_prefix" {
  type = string
}
variable "metastore_mode" {
  description = "create: manage a dedicated metastore. existing: assign existing_metastore_name. auto: assign the account's metastore in var.region if one exists, otherwise create one."
  type        = string
  default     = "create"

  validation {
    condition     = contains(["create", "existing", "auto"], var.metastore_mode)
    error_message = "metastore_mode must be create, existing, or auto."
  }
}
variable "existing_metastore_name" {
  description = "Existing regional metastore to assign when metastore_mode is existing."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.existing_metastore_name == null || trimspace(var.existing_metastore_name) != ""
    error_message = "existing_metastore_name must be null or a non-empty metastore name."
  }
}
variable "create_initial_catalog" {
  description = "Create dedicated S3 storage, a storage credential, an external location, and the initial catalog."
  type        = bool
  default     = true
}
variable "catalog_name" {
  type    = string
  default = "main"
}
variable "force_destroy" {
  description = "Allow deletion of non-empty Unity Catalog and S3 resources. Keep false outside disposable environments."
  type        = bool
  default     = false
}
variable "tags" {
  type = map(string)
  default = {
  }
}
