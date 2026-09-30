subscription_id = "00000000-0000-0000-0000-000000000000"
location        = "westus2"

features = {
  workspace  = true
  custom_dns = true
}

workspace_network = {
  vnet_cidr                    = "10.70.0.0/16"
  host_subnet_cidr             = "10.70.0.0/24"
  container_subnet_cidr        = "10.70.1.0/24"
  private_endpoint_subnet_cidr = "10.70.2.0/26"
  dns_subnet_cidr              = "10.70.3.0/27"
  dns_server_ip                = "10.70.3.4"
}

tags = {
  ManagedBy   = "terraform"
  Environment = "demo"
  Owner       = "platform-team"
}
