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
