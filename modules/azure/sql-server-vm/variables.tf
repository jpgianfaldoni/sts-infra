variable "name_prefix" {
  type = string
}
variable "location" {
  type = string
}
variable "resource_group_name" {
  type    = string
  default = null
}
variable "vnet_address_space" {
  type    = list(string)
  default = ["10.90.0.0/16"]
}
variable "vm_subnet_prefixes" {
  type    = list(string)
  default = ["10.90.1.0/24"]
}
variable "private_link_service_subnet_prefixes" {
  type    = list(string)
  default = ["10.90.2.0/24"]
}
variable "vm_private_ip" {
  type    = string
  default = "10.90.1.4"
}
variable "vm_size" {
  type    = string
  default = "Standard_D4s_v5"
}
variable "vm_admin_username" {
  type    = string
  default = "localadmin"
}
variable "sql_admin_username" {
  type    = string
  default = "sqladminuser"
}
variable "tags" {
  type = map(string)
  default = {
  }
}
variable "lakeflow_connect_enabled" {
  description = "Prepare SQL Server for Lakeflow Connect CDC from inside the VM: sample data, an ingestion login, the utility objects, and CDC on the sample tables."
  type        = bool
  default     = false
}
variable "lakeflow_username" {
  description = "SQL login dedicated to Lakeflow Connect ingestion."
  type        = string
  default     = "lakeflow"

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_]{0,63}$", var.lakeflow_username)) && lower(var.lakeflow_username) != lower(var.sql_admin_username)
    error_message = "lakeflow_username must be a simple SQL identifier different from the administrator login."
  }
}
variable "lakeflow_utility_script_url" {
  description = "Download location of the Databricks Lakeflow Connect SQL Server utility objects script; the VM fetches it during setup."
  type        = string
  default     = "https://learn.microsoft.com/en-us/azure/databricks/_extras/documents/utility_script.sql"

  validation {
    condition     = startswith(var.lakeflow_utility_script_url, "https://") && !strcontains(var.lakeflow_utility_script_url, "'")
    error_message = "lakeflow_utility_script_url must be an https URL without single quotes."
  }
}
variable "private_dns_name" {
  description = "Optional private hostname for SQL Server, such as sqlserver.lab.internal. A private DNS zone linked only to the SQL VNet resolves it to the VM's private IP."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.private_dns_name == null || can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$", var.private_dns_name))
    error_message = "private_dns_name must be a lowercase DNS name with at least two labels, such as sqlserver.lab.internal."
  }
}
