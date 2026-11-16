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
    resource_id  = string
    group_id     = optional(string)
    domain_names = optional(list(string), [])
  }))
  default = {}

  validation {
    condition     = alltrue([for key in keys(var.private_endpoint_rules) : contains(["sql_database", "mysql_flexible_server", "sql_server_vm"], key)])
    error_message = "Each private endpoint rule key must be a source this module creates a rule resource for; add a resource for a new source."
  }

  validation {
    condition     = alltrue([for rule in values(var.private_endpoint_rules) : (rule.group_id != null) != (length(rule.domain_names) > 0)])
    error_message = "A rule must set either a managed resource group_id or custom service domain_names."
  }
}
