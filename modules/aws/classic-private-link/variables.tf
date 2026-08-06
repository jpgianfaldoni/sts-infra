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

variable "tags" {
  type = map(string)
  default = {
  }
}
