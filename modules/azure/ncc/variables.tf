variable "network_connectivity_config_id" {
  description = "NCC that receives the private endpoint rules and the workspace binding."
  type        = string
}

variable "workspace_id" {
  type = number
}

variable "private_endpoint_rules" {
  description = "Azure resources that serverless compute reaches privately, keyed by component."
  type = map(object({
    resource_id = string
    group_id    = string
  }))
  default = {}

  validation {
    condition     = alltrue([for key in keys(var.private_endpoint_rules) : contains(["sql_database", "mysql_flexible_server"], key)])
    error_message = "Each private endpoint rule key must be a source this module creates a rule resource for; add a resource for a new source."
  }
}
