variable "name" {
  description = "Name used for Transit Gateway resources."
  type        = string
}

variable "availability_zones" {
  description = "Availability zones used for dedicated attachment subnets."
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) == 2 && var.availability_zones[0] != var.availability_zones[1]
    error_message = "Exactly two distinct availability zones are required."
  }
}

variable "workspace_vpc_id" {
  type = string
}

variable "workspace_vpc_cidr" {
  type = string
}

variable "workspace_attachment_subnet_cidrs" {
  description = "Dedicated Transit Gateway subnet CIDRs in the workspace VPC."
  type        = list(string)

  validation {
    condition = length(var.workspace_attachment_subnet_cidrs) == 2 && alltrue([
      for cidr in var.workspace_attachment_subnet_cidrs : can(cidrnetmask(cidr)) && !strcontains(cidr, ":")
    ])
    error_message = "Provide exactly two valid IPv4 workspace attachment subnet CIDRs."
  }
}

variable "workspace_existing_subnet_cidrs" {
  description = "Existing workspace subnet CIDRs checked for overlap with attachment subnets."
  type        = list(string)
}

variable "workspace_route_table_ids" {
  description = "Workspace workload route tables that need a route to simulated on-premises."
  type        = list(string)
}

variable "workspace_security_group_id" {
  description = "Security group attached to Databricks classic-compute ENIs."
  type        = string
}

variable "on_prem_vpc_id" {
  type = string
}

variable "on_prem_vpc_cidr" {
  type = string
}

variable "on_prem_attachment_subnet_cidrs" {
  description = "Dedicated Transit Gateway subnet CIDRs in the simulated on-premises VPC."
  type        = list(string)

  validation {
    condition = length(var.on_prem_attachment_subnet_cidrs) == 2 && alltrue([
      for cidr in var.on_prem_attachment_subnet_cidrs : can(cidrnetmask(cidr)) && !strcontains(cidr, ":")
    ])
    error_message = "Provide exactly two valid IPv4 simulated on-premises attachment subnet CIDRs."
  }
}

variable "on_prem_existing_subnet_cidrs" {
  description = "Existing simulated on-premises subnet CIDRs checked for overlap with attachment subnets."
  type        = list(string)
}

variable "on_prem_route_table_ids" {
  description = "Simulated on-premises workload route tables that need a route to the workspace."
  type        = list(string)
}

variable "on_prem_security_group_id" {
  description = "Security group attached to the simulated on-premises test host."
  type        = string
}

variable "service_port" {
  description = "TCP test-service port allowed from Databricks classic compute."
  type        = number
}

variable "tags" {
  type    = map(string)
  default = {}
}
