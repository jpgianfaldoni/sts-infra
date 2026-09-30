variable "name_prefix" {
  type = string
}

variable "location" {
  type = string
}

variable "tenant_id" {
  type = string
}

variable "operator_object_id" {
  description = "Principal running Terraform; it receives Key Vault Secrets Officer to write the secrets."
  type        = string
}

variable "secret_names" {
  description = "Names of the secrets to store (non-sensitive so they can drive for_each)."
  type        = list(string)
}

variable "secrets" {
  description = "Secret values keyed by name."
  type        = map(string)
  sensitive   = true
}

variable "databricks_secret_scope_enabled" {
  description = "Create a Key Vault-backed Databricks secret scope in the workspace."
  type        = bool
  default     = false
}

variable "secret_scope_name" {
  type    = string
  default = "sts-infra"
}

variable "tags" {
  type    = map(string)
  default = {}
}
