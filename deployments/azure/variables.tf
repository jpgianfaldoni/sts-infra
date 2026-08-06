variable "subscription_id" {
  type = string
}
variable "location" {
  type    = string
  default = "westus2"
}
variable "name_prefix" {
  type    = string
  default = "demo"
}
variable "workspace_name" {
  type    = string
  default = "demo-azure-classic"
}
variable "features" {
  type = object({
    workspace     = optional(bool, true)
    sql_database  = optional(bool, false)
    sql_server_vm = optional(bool, false)
  })
  default = {
  }
}
variable "workspace_network" {
  type = object({ vnet_cidr = string
    host_subnet_cidr             = string
    container_subnet_cidr        = string
    private_endpoint_subnet_cidr = string
  })
  default = { vnet_cidr = "10.70.0.0/16"
    host_subnet_cidr             = "10.70.0.0/24"
    container_subnet_cidr        = "10.70.1.0/24"
    private_endpoint_subnet_cidr = "10.70.2.0/26"
  }
}
variable "sql_database_network" {
  type = object({ vnet_address_space = list(string)
    private_endpoint_subnet_prefixes = list(string)
  })
  default = { vnet_address_space = ["10.80.0.0/16"]
    private_endpoint_subnet_prefixes = ["10.80.1.0/24"]
  }
}
variable "sql_vm_network" {
  type = object({ vnet_address_space = list(string)
    vm_subnet_prefixes                   = list(string)
    private_link_service_subnet_prefixes = list(string)
    vm_private_ip                        = string
  })
  default = { vnet_address_space = ["10.90.0.0/16"]
    vm_subnet_prefixes                   = ["10.90.1.0/24"]
    private_link_service_subnet_prefixes = ["10.90.2.0/24"]
    vm_private_ip                        = "10.90.1.4"
  }
}
variable "tags" {
  type = map(string)
  default = { ManagedBy = "terraform"
    Environment = "demo"
  }
}
