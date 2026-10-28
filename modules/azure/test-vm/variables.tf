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

variable "allowed_ssh_source_cidr" {
  type = string
}

variable "admin_principal_object_id" {
  type = string
}

variable "admin_username" {
  type    = string
  default = "azureuser"
}

variable "admin_ssh_public_key" {
  description = "Optional OpenSSH public key for the admin user. When set, password authentication is disabled."
  type        = string
  default     = null
  nullable    = true
}

variable "vm_size" {
  type    = string
  default = "Standard_B2s"
}

variable "tags" {
  type    = map(string)
  default = {}
}
