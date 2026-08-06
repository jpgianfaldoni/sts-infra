variable "resource_name" {
  description = "Unique lowercase name used for the private database network."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the isolated database VPC."
  type        = string
}

variable "availability_zone_count" {
  description = "Number of database subnets in distinct availability zones."
  type        = number
  default     = 2

  validation {
    condition     = var.availability_zone_count >= 2
    error_message = "availability_zone_count must be at least two."
  }
}

variable "tags" {
  description = "Tags applied to supported resources."
  type        = map(string)
  default = {
  }
}
