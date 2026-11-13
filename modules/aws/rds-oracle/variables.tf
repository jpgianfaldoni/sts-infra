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
variable "engine" {
  description = "RDS for Oracle engine. Lakeflow Connect needs a non-multitenant (non-CDB) database."
  type        = string
  default     = "oracle-se2"

  validation {
    condition     = contains(["oracle-se2", "oracle-ee"], var.engine)
    error_message = "engine must be a non-CDB RDS for Oracle engine: oracle-se2 or oracle-ee."
  }
}
variable "engine_version" {
  description = "Oracle version; 19 selects the latest 19c release update."
  type        = string
  default     = "19"
}
variable "database_name" {
  description = "Database name, which is also the service name clients connect to."
  type        = string
  default     = "DEMO"
}
variable "master_username" {
  type    = string
  default = "admin"
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
  description = "Create a write-only Secrets Manager credential for the Lakeflow Connect replication user; the lab check job creates it and enables LogMiner CDC."
  type        = bool
  default     = true
}
