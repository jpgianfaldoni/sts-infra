variable "name_prefix" {
  type = string
}
variable "location" {
  type = string
}
variable "vnet_address_space" {
  type    = list(string)
  default = ["10.93.0.0/16"]
}
variable "vm_subnet_prefixes" {
  type    = list(string)
  default = ["10.93.1.0/24"]
}
variable "vm_private_ip" {
  type    = string
  default = "10.93.1.4"
}
variable "vm_size" {
  description = "Oracle Database Free uses up to 2 CPUs and 2 GB of memory; the installer needs more memory than that."
  type        = string
  default     = "Standard_D2s_v5"
}
variable "vm_admin_username" {
  type    = string
  default = "azureuser"
}
variable "oracle_rpm_url" {
  description = "Oracle Database Free RPM for Oracle Linux 8, downloaded by the VM during setup."
  type        = string
  default     = "https://download.oracle.com/otn-pub/otn_software/db-free/oracle-database-free-23ai-1.0-1.el8.x86_64.rpm"

  validation {
    condition     = startswith(var.oracle_rpm_url, "https://") && !strcontains(var.oracle_rpm_url, "'")
    error_message = "oracle_rpm_url must be an https URL without single quotes."
  }
}
variable "lakeflow_connect_enabled" {
  description = "Prepare Oracle for Lakeflow Connect from inside the VM: ARCHIVELOG mode, supplemental logging, sample data, and a C##LAKEFLOW common user created with the Databricks setup package."
  type        = bool
  default     = true
}
variable "private_dns_name" {
  description = "Optional private hostname, such as oracle.lab.internal, resolved inside the VM's VNet only."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.private_dns_name == null || can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$", var.private_dns_name))
    error_message = "private_dns_name must be a lowercase DNS name with at least two labels."
  }
}
variable "tags" {
  type    = map(string)
  default = {}
}
