variable "name" {
  description = "Name applied to the peering connection and rules."
  type        = string
}

variable "client_vpc_id" {
  type = string
}

variable "client_vpc_cidr" {
  type = string
}

variable "client_route_table_ids" {
  type = list(string)
}

variable "client_security_group_id" {
  type = string
}

variable "service_vpc_id" {
  type = string
}

variable "service_vpc_cidr" {
  type = string
}

variable "service_route_table_ids" {
  type = list(string)
}

variable "service_security_group_id" {
  type = string
}

variable "service_port" {
  type = number
}

variable "tags" {
  type = map(string)
  default = {
  }
}
