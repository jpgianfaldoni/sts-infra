variable "name_prefix" {
  type = string
}
variable "region" {
  type = string
}
variable "vpc_cidr" {
  type = string
}
variable "instance_class" {
  type    = string
  default = "db.m5.large"
}
variable "engine_version" {
  type    = string
  default = null
}
variable "master_username" {
  type    = string
  default = "sqladminuser"
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
