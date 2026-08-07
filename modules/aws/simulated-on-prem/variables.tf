variable "name_prefix" {
  description = "Prefix used for simulated on-premises resources."
  type        = string
}

variable "region" {
  description = "AWS region for the simulated on-premises network."
  type        = string
}

variable "availability_zone" {
  description = "Availability zone for the private workload subnet."
  type        = string
}

variable "vpc_cidr" {
  description = "IPv4 CIDR for the simulated on-premises VPC."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && !strcontains(var.vpc_cidr, ":")
    error_message = "vpc_cidr must be a valid IPv4 CIDR."
  }
}

variable "workload_subnet_cidr" {
  description = "IPv4 CIDR for the private EC2 workload subnet."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.workload_subnet_cidr)) && !strcontains(var.workload_subnet_cidr, ":")
    error_message = "workload_subnet_cidr must be a valid IPv4 CIDR."
  }
}

variable "instance_type" {
  description = "EC2 instance type for the private test host."
  type        = string
}

variable "service_port" {
  description = "TCP port exposed by the test HTTP service."
  type        = number

  validation {
    condition     = var.service_port >= 1 && var.service_port <= 65535
    error_message = "service_port must be between 1 and 65535."
  }
}

variable "tags" {
  description = "Tags applied to simulated on-premises resources."
  type        = map(string)
  default     = {}
}
