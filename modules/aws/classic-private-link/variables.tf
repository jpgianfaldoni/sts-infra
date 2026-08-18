variable "name" {
  description = "Name for the classic-compute interface endpoint."
  type        = string
}

variable "vpc_id" {
  description = "Databricks classic compute VPC ID."
  type        = string
}

variable "subnet_ids" {
  description = "Private classic compute subnet IDs for endpoint ENIs."
  type        = list(string)
}

variable "client_security_group_id" {
  description = "Security group attached to classic cluster nodes."
  type        = string
}

variable "endpoint_service_name" {
  description = "AWS VPC endpoint service name exposed by the target NLB."
  type        = string
}

variable "service_port" {
  description = "TCP port exposed by the target service."
  type        = number
}

variable "private_dns_name" {
  description = "Optional service hostname to resolve to this interface endpoint. Required when the application advertises its own hostname, as Kafka does."
  type        = string
  default     = null
  nullable    = true
}

variable "create_private_dns_alias" {
  description = "Create a private hosted-zone alias from private_dns_name to the interface endpoint."
  type        = bool
  default     = false
}

variable "tags" {
  type = map(string)
  default = {
  }
}
