variable "name_prefix" {
  type = string
}
variable "location" {
  type = string
}
variable "vnet_address_space" {
  type    = list(string)
  default = ["10.82.0.0/16"]
}
variable "private_endpoint_subnet_prefixes" {
  type    = list(string)
  default = ["10.82.1.0/24"]
}
variable "mysql_version" {
  description = "Azure Database for MySQL Flexible Server version."
  type        = string
  default     = "8.4"
}
variable "sku_name" {
  type    = string
  default = "B_Standard_B1ms"
}
variable "database_name" {
  type    = string
  default = "demo"
}
variable "admin_username" {
  type    = string
  default = "labadmin"
}
variable "lakeflow_connect_enabled" {
  description = "Set seven-day binary log retention and generate a lakeflow replication user that the lab check job creates."
  type        = bool
  default     = true
}
variable "tags" {
  type    = map(string)
  default = {}
}
