variable "cloud" {
  description = "aws or azure; used in the troubleshooting hints the checks print."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for the job, notebook folder, and secret scope names."
  type        = string
}

variable "checks" {
  description = "Connectivity checks keyed by <source>_<compute path>. Database checks load the sample data before they verify the path."
  type = map(object({
    source        = string
    path          = string
    mode          = string
    engine        = string
    host          = string
    port          = number
    database      = optional(string)
    seed_database = optional(string)
    seed_file     = optional(string)
    secret_scope  = optional(string)
    username_key  = optional(string)
    password_key  = optional(string)
    run_after     = optional(string)
  }))

  validation {
    condition     = alltrue([for check in values(var.checks) : contains(["classic", "serverless"], check.path)])
    error_message = "Each check path must be classic or serverless."
  }

  validation {
    condition     = alltrue([for check in values(var.checks) : contains(["postgresql", "sqlserver", "tcp"], check.engine)])
    error_message = "Each check engine must be postgresql, sqlserver, or tcp."
  }

  validation {
    condition = alltrue([
      for check in values(var.checks) :
      check.engine == "tcp" || (check.secret_scope != null && check.username_key != null && check.password_key != null && check.database != null)
    ])
    error_message = "Database checks need database, secret_scope, username_key, and password_key."
  }
}

variable "managed_secret_scope" {
  description = "Name of a Databricks-backed secret scope to create for check credentials (./infra verify fills it). Null when the checks use an existing scope."
  type        = string
  default     = null
  nullable    = true
}

variable "classic_node_type" {
  description = "Node type for the single-node classic check cluster. When null, the smallest general-purpose node type with at least 4 cores is used. Any node type works: the cluster attaches storage as it needs it."
  type        = string
  default     = null
  nullable    = true
}
