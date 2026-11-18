variable "location" {
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

variable "test_vm_subnet_cidr" {
  type     = string
  nullable = true
  default  = null
}

variable "gateway_subnet_cidr" {
  description = "CIDR (/28 or larger) of the subnet delegated to the serverless private network gateway; null creates none."
  type        = string
  nullable    = true
  default     = null
}

variable "dns_subnet_cidr" {
  type = string
}

variable "dns_server_ip" {
  type     = string
  nullable = true
  default  = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
