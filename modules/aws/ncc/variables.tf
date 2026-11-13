variable "network_connectivity_config_id" {
  description = "NCC that receives the private endpoint rules."
  type        = string
}
variable "private_endpoint_rules" {
  type = map(object({
    endpoint_service = string
    domain_names     = list(string)
  }))
  default = {
  }

  validation {
    condition     = alltrue([for key in keys(var.private_endpoint_rules) : contains(["rds_postgres", "rds_sql_server", "rds_mysql", "rds_oracle", "aurora_postgres", "rabbitmq", "kafka", "simulated_on_prem"], key)])
    error_message = "Each private endpoint rule key must be a source this module creates a rule resource for; add a resource for a new source."
  }
}
