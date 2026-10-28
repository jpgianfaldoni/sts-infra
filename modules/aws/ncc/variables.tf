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
}
