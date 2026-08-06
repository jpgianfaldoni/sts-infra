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
