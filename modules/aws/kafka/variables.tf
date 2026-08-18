variable "name_prefix" {
  description = "Prefix for Kafka lab resources."
  type        = string
}

variable "region" {
  description = "AWS region for the Kafka lab."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR for the dedicated Kafka VPC."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for the single Kafka broker."
  type        = string
  default     = "t3.small"
}

variable "kafka_image" {
  description = "Pinned Apache Kafka Docker image."
  type        = string
  default     = "apache/kafka:3.9.1"
}

variable "topic_name" {
  description = "Topic populated by the synthetic event producer."
  type        = string
  default     = "demo-events"

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+$", var.topic_name))
    error_message = "topic_name may contain only letters, numbers, dots, underscores, and hyphens."
  }
}

variable "producer_interval_seconds" {
  description = "Delay between synthetic JSON events."
  type        = number
  default     = 1

  validation {
    condition     = var.producer_interval_seconds >= 1 && var.producer_interval_seconds <= 3600
    error_message = "producer_interval_seconds must be between 1 and 3600."
  }
}

variable "broker_username" {
  description = "SASL/PLAIN username stored with its generated password in Secrets Manager."
  type        = string
  default     = "kafkaadmin"

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_]*$", var.broker_username))
    error_message = "broker_username must start with a letter and contain only letters, numbers, and underscores."
  }
}

variable "enable_classic_private_link" {
  type    = bool
  default = false
}

variable "enable_serverless_private_link" {
  type    = bool
  default = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
