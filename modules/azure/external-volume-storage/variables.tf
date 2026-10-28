variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "resource_prefix" {
  type = string
}

variable "workspace_id" {
  description = "Numeric Databricks workspace ID to assign to the project metastore."
  type        = string
}

variable "seed_principal_object_id" {
  description = "Azure principal allowed to upload the initial sample files."
  type        = string
}

variable "public_network_access_enabled" {
  description = "Whether the storage public endpoint remains enabled after bootstrap."
  type        = bool
  default     = false
}

variable "bootstrap_access_enabled" {
  description = "Whether temporary operator-only public access is enabled for sample seeding."
  type        = bool
  default     = false
}

variable "bootstrap_operator_cidr" {
  description = "Public CIDR allowed to seed data while bootstrap access is enabled."
  type        = string
  default     = null
  nullable    = true
}

variable "container_name" {
  type    = string
  default = "external-volume"
}

variable "catalog_name" {
  type    = string
  default = "azure_storage_demo"
}

variable "schema_name" {
  type    = string
  default = "demo"
}

variable "volume_name" {
  type    = string
  default = "private_json"
}

variable "volume_storage_path" {
  type    = string
  default = "volume"
}

variable "metastore_mode" {
  description = "create a project metastore, assign an existing one, or auto: reuse the account's metastore in this region when one exists, else create one."
  type        = string
  default     = "create"

  validation {
    condition     = contains(["create", "existing", "auto"], var.metastore_mode)
    error_message = "metastore_mode must be create, existing, or auto."
  }
}

variable "existing_metastore_id" {
  description = "Existing metastore ID when metastore_mode is existing."
  type        = string
  default     = null
  nullable    = true
}

variable "allow_force_destroy" {
  description = "Allow Terraform to force-delete non-empty Unity Catalog resources in this disposable environment."
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
