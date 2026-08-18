variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "resource_prefix" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "private_ip" {
  type = string
}

variable "vm_size" {
  type    = string
  default = "Standard_B1s"
}

variable "admin_username" {
  type    = string
  default = "dnsadmin"
}

variable "tags" {
  type    = map(string)
  default = {}
}
