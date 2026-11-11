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
  default = "db.t4g.micro"
}
variable "engine_version" {
  description = "MySQL major version; also selects the parameter group family (mysql<version>)."
  type        = string
  default     = "8.4"
}
variable "database_name" {
  type    = string
  default = "demo"
}
variable "master_username" {
  type    = string
  default = "labadmin"
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
variable "lakeflow_connect_enabled" {
  description = "Create a write-only Secrets Manager credential for the Lakeflow Connect replication user; the lab check job creates the user and its grants."
  type        = bool
  default     = true
}
