variable "name" {
  description = "Display name of the gateway."
  type        = string
}

variable "databricks_account_id" {
  type = string
}

variable "network_connectivity_config_id" {
  description = "NCC that owns the gateway. It must be attached to the workspace and be in the subnet's region."
  type        = string
}

variable "subnet_id" {
  description = "Azure resource ID of a dedicated subnet delegated to Microsoft.Databricks/workspaces."
  type        = string
}

variable "destinations" {
  description = "DNS names serverless compute reaches through the gateway. A name also matches its subdomains."
  type        = list(string)

  validation {
    condition     = length(var.destinations) > 0 && length(var.destinations) <= 100
    error_message = "A gateway in SPECIFIC_DESTINATIONS mode needs between 1 and 100 destinations."
  }
}

variable "bandwidth_tier_gbps" {
  type    = number
  default = 10

  validation {
    condition     = contains([10, 30, 50, 100], var.bandwidth_tier_gbps)
    error_message = "bandwidth_tier_gbps must be 10, 30, 50, or 100."
  }
}

variable "private_dns_resolvers" {
  description = "Custom DNS resolver IP addresses reachable from the gateway subnet. Empty uses Azure-provided DNS, which resolves private DNS zones linked to the VNet."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.private_dns_resolvers) <= 2
    error_message = "A gateway supports at most two DNS resolvers."
  }
}
