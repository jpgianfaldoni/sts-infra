variable "location" {
  type = string
}
variable "workspace_name" {
  type = string
}
variable "resource_prefix" {
  type = string
}
variable "vnet_cidr" {
  type = string
}
variable "host_subnet_cidr" {
  type = string
}
variable "container_subnet_cidr" {
  type = string
}
variable "private_endpoint_subnet_cidr" {
  type = string
}
variable "tags" {
  type = map(string)
  default = {
  }
}
