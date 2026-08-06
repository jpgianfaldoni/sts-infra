variable "region" {
  type    = string
  default = "us-west-2"
}
variable "aws_profile" {
  type    = string
  default = null
}
variable "databricks_profile" {
  type    = string
  default = "DEFAULT"
}
variable "databricks_workspace_profile" {
  description = "Optional workspace-scoped Databricks CLI profile. Required for workspace APIs when the account profile cannot authenticate to the workspace."
  type        = string
  default     = null
  nullable    = true
}
variable "databricks_account_id" {
  type = string
}
variable "name_prefix" {
  type    = string
  default = "demo"
}
variable "workspace_name" {
  type    = string
  default = "demo-classic"
}
variable "availability_zones" {
  type    = list(string)
  default = ["us-west-2a", "us-west-2b"]
}
variable "workspace_network" {
  type = object({
    vpc_cidr             = string
    private_subnet_cidrs = list(string)
    public_subnet_cidr   = string
  })
  default = { vpc_cidr = "10.40.0.0/18"
    private_subnet_cidrs = ["10.40.0.0/20", "10.40.16.0/20"]
    public_subnet_cidr   = "10.40.32.0/24"
  }
}
variable "features" {
  type = object({
    workspace       = optional(bool, true)
    unity_catalog   = optional(bool, true)
    rds_postgres    = optional(bool, false)
    rds_sql_server  = optional(bool, false)
    aurora_postgres = optional(bool, false)
    aurora_proxy    = optional(bool, false)
    rabbitmq        = optional(bool, false)
  })
  default = {
  }
  validation {
    condition     = (!var.features.unity_catalog || var.features.workspace) && (!var.features.aurora_proxy || var.features.aurora_postgres)
    error_message = "unity_catalog requires workspace; aurora_proxy requires aurora_postgres."
  }
}
variable "connectivity" {
  description = "Choose classic and serverless connectivity independently for each service."
  type = object({
    rds_postgres = optional(object({
      classic    = optional(string, "none")
      serverless = optional(string, "none")
    }), {})
    rds_sql_server = optional(object({
      classic    = optional(string, "none")
      serverless = optional(string, "none")
    }), {})
    aurora_postgres = optional(object({
      classic    = optional(string, "none")
      serverless = optional(string, "none")
    }), {})
    rabbitmq = optional(object({
      classic    = optional(string, "none")
      serverless = optional(string, "none")
    }), {})
  })
  default = {
  }
  validation {
    condition = alltrue([for value in [
      var.connectivity.rds_postgres.classic,
      var.connectivity.rds_sql_server.classic,
      var.connectivity.aurora_postgres.classic,
      var.connectivity.rabbitmq.classic
    ] : contains(["none", "peering", "private_link"], value)])
    error_message = "Classic connectivity modes must be none, peering, or private_link."
  }
  validation {
    condition = alltrue([for value in [
      var.connectivity.rds_postgres.serverless,
      var.connectivity.rds_sql_server.serverless,
      var.connectivity.aurora_postgres.serverless,
      var.connectivity.rabbitmq.serverless
    ] : contains(["none", "private_link"], value)])
    error_message = "Serverless connectivity modes must be none or private_link."
  }
  validation {
    condition = var.features.workspace || alltrue([for value in [
      var.connectivity.rds_postgres.classic,
      var.connectivity.rds_postgres.serverless,
      var.connectivity.rds_sql_server.classic,
      var.connectivity.rds_sql_server.serverless,
      var.connectivity.aurora_postgres.classic,
      var.connectivity.aurora_postgres.serverless,
      var.connectivity.rabbitmq.classic,
      var.connectivity.rabbitmq.serverless
    ] : value == "none"])
    error_message = "Databricks connectivity requires the workspace feature."
  }
  validation {
    condition = alltrue([
      var.features.rds_postgres || (var.connectivity.rds_postgres.classic == "none" && var.connectivity.rds_postgres.serverless == "none"),
      var.features.rds_sql_server || (var.connectivity.rds_sql_server.classic == "none" && var.connectivity.rds_sql_server.serverless == "none"),
      var.features.aurora_postgres || (var.connectivity.aurora_postgres.classic == "none" && var.connectivity.aurora_postgres.serverless == "none"),
      var.features.rabbitmq || (var.connectivity.rabbitmq.classic == "none" && var.connectivity.rabbitmq.serverless == "none")
    ])
    error_message = "Connectivity can only be enabled for a service whose feature is enabled."
  }
}
variable "database_networks" {
  type = object({ rds_postgres = string
    rds_sql_server  = string
    aurora_postgres = string
    rabbitmq        = string
  })
  default = { rds_postgres = "10.45.0.0/16"
    rds_sql_server  = "10.43.0.0/16"
    aurora_postgres = "10.46.0.0/16"
    rabbitmq        = "10.47.0.0/16"
  }
}
variable "initial_catalog_name" {
  type    = string
  default = "main"
}
variable "allow_destructive_demo_cleanup" {
  type    = bool
  default = false
}
variable "tags" {
  type = map(string)
  default = { ManagedBy = "terraform"
    Environment = "demo"
  }
}
