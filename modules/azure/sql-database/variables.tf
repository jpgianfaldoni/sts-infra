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
  default = ["10.80.0.0/16"]
}
variable "private_endpoint_subnet_prefixes" {
  type    = list(string)
  default = ["10.80.1.0/24"]
}
variable "database_name" {
  type    = string
  default = "demo"
}
variable "admin_username" {
  type    = string
  default = "sqladminuser"
}
variable "tags" {
  type = map(string)
  default = {
  }
}
