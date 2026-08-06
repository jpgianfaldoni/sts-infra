variable "name_prefix" {
  type = string
}
variable "region" {
  type = string
}
variable "vpc_cidr" {
  type = string
}
variable "instance_type" {
  type    = string
  default = "t3.micro"
}
variable "rabbitmq_image" {
  type    = string
  default = "rabbitmq:3.13-management"
}
variable "broker_username" {
  type    = string
  default = "rabbitadmin"
}
variable "enable_classic_private_link" {
  type    = bool
  default = false
}
variable "enable_serverless_private_link" {
  type    = bool
  default = false
}
variable "tags" {
  type = map(string)
  default = {
  }
}
