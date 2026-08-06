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
