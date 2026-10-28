variable "name" {
  description = "Name prefix for the peerings and DNS links."
  type        = string
}

variable "local_vnet" {
  type = object({
    id                  = string
    name                = string
    resource_group_name = string
  })
}

variable "remote_vnet" {
  type = object({
    id                  = string
    name                = string
    resource_group_name = string
  })
}

variable "private_dns_zone_links" {
  description = "Private DNS zones to link to an additional VNet, keyed by a short name."
  type = map(object({
    private_dns_zone_name = string
    resource_group_name   = string
    virtual_network_id    = string
  }))
  default = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}
