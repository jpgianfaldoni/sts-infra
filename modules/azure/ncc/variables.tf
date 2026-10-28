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
}
