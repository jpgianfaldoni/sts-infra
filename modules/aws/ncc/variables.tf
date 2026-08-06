variable "name" {
  type = string
}
variable "region" {
  type = string
}
variable "workspace_id" {
  type = number
}
variable "private_endpoint_rules" {
  type = map(object({
    endpoint_service = string
    domain_names     = list(string)
  }))
  default = {
  }
}
