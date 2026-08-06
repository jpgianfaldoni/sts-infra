variable "name_prefix" {
  type = string
}
variable "region" {
  type = string
}
variable "vpc_cidr" {
  type = string
}
variable "instance_count" {
  type    = number
  default = 2
}
variable "instance_class" {
  type    = string
  default = "db.t4g.medium"
}
variable "engine_version" {
  type    = string
  default = null
}
variable "database_name" {
  type    = string
  default = "demo"
}
variable "master_username" {
  type    = string
  default = "auroraadmin"
}
variable "enable_proxy" {
  type    = bool
  default = false
}
variable "enable_classic_private_link" {
  type    = bool
  default = false
}
variable "enable_serverless_private_link" {
  type    = bool
  default = false
}
variable "deletion_protection" {
  type    = bool
  default = true
}
variable "skip_final_snapshot" {
  type    = bool
  default = false
}
variable "tags" {
  type = map(string)
  default = {
  }
}
