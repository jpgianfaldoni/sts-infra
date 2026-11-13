variable "name_prefix" {
  type = string
}
variable "location" {
  type = string
}
variable "vnet_address_space" {
  type    = list(string)
  default = ["10.92.0.0/16"]
}
variable "vm_subnet_prefixes" {
  type    = list(string)
  default = ["10.92.1.0/24"]
}
variable "vm_private_ip" {
  type    = string
  default = "10.92.1.4"
}
variable "vm_size" {
  # Burstable B-series sizes failed allocation in testing when Run Command
  # updated the VM; general-purpose D-series sizes did not.
  type    = string
  default = "Standard_D2s_v5"
}
variable "vm_admin_username" {
  type    = string
  default = "azureuser"
}
variable "mysql_admin_username" {
  type    = string
  default = "labadmin"
}
variable "lakeflow_connect_enabled" {
  description = "Prepare MySQL for Lakeflow Connect from inside the VM: binary logging, seven-day retention, sample data, and a lakeflow replication user."
  type        = bool
  default     = true
}
variable "private_dns_name" {
  description = "Optional private hostname, such as mysql.lab.internal, resolved inside the VM's VNet only."
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
