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
  type    = string
  default = null
}
variable "lakeflow_connect_enabled" {
  description = "Enable logical-replication parameters and a dedicated write-only replication credential for Lakeflow Connect source setup."
  type        = bool
  default     = false

  validation {
    condition = !var.lakeflow_connect_enabled || (
      try(tonumber(split(".", var.engine_version)[0]), 0) >= 13
    )
    error_message = "lakeflow_connect_enabled requires an explicit PostgreSQL engine_version of 13 or newer."
  }
}
variable "database_name" {
  type    = string
  default = "demo"
}
variable "master_username" {
  type    = string
  default = "postgresadmin"
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
