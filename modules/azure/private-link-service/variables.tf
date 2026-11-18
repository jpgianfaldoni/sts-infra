variable "name" {
  type = string
}
variable "location" {
  type = string
}
variable "resource_group_name" {
  type = string
}
variable "frontend_subnet_id" {
  description = "Subnet for the internal load balancer frontend."
  type        = string
}
variable "nat_subnet_id" {
  description = "Separate subnet with Private Link Service network policies disabled."
  type        = string
}
variable "network_interface_id" {
  description = "Backend VM NIC; the service has no public frontend."
  type        = string
}
variable "ip_configuration_name" {
  type    = string
  default = "primary"
}
variable "port" {
  type = number
}
variable "tags" {
  type    = map(string)
  default = {}
}
