variable "databricks_account_id" {
  description = "Databricks account ID."
  type        = string
}

variable "region" {
  description = "AWS region for the workspace."
  type        = string
}

variable "workspace_name" {
  description = "Databricks workspace display name."
  type        = string
}

variable "resource_prefix" {
  description = "Lowercase prefix for workspace resources."
  type        = string
}

variable "pricing_tier" {
  type    = string
  default = "ENTERPRISE"
}

variable "vpc_cidr" {
  type = string
}

variable "availability_zones" {
  type = list(string)

  validation {
    condition     = length(var.availability_zones) == 2 && var.availability_zones[0] != var.availability_zones[1]
    error_message = "Exactly two distinct availability zones are required."
  }
}

variable "private_subnet_cidrs" {
  type = list(string)

  validation {
    condition     = length(var.private_subnet_cidrs) == 2
    error_message = "Exactly two private subnet CIDRs are required."
  }
}

variable "public_subnet_cidr" {
  type = string
}

variable "backend_private_link" {
  description = "Back-end PrivateLink configuration for workspace-to-control-plane traffic."
  type = object({
    enabled               = bool
    endpoint_subnet_cidrs = list(string)
    public_access_enabled = bool
  })
  default = {
    enabled               = false
    endpoint_subnet_cidrs = []
    public_access_enabled = true
  }

  validation {
    condition = !var.backend_private_link.enabled || (
      length(var.backend_private_link.endpoint_subnet_cidrs) == 2 &&
      alltrue([
        for cidr in var.backend_private_link.endpoint_subnet_cidrs :
        can(cidrnetmask(cidr)) && !strcontains(cidr, ":")
      ])
    )
    error_message = "Back-end PrivateLink requires exactly two valid IPv4 endpoint subnet CIDRs."
  }
}

variable "force_destroy_root_bucket" {
  description = "Allow deletion of a non-empty workspace root bucket."
  type        = bool
  default     = false
}

variable "tags" {
  type = map(string)
  default = {
  }
}
variable "network_connectivity_config_id" {
  description = "Optional NCC attached to the workspace for serverless private endpoints."
  type        = string
  default     = null
  nullable    = true
}
