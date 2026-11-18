# Azure Databricks private network gateway (Public Preview): serverless compute
# enters the customer VNet through a subnet delegated to Databricks and reaches
# whatever that VNet routes to. Only the listed DNS names use the gateway, and
# Databricks allows them in serverless egress control automatically.

# Deleting a gateway returns before Databricks finishes removing its network
# interface from the subnet. Terraform destroys the gateway first and then
# waits here, so the subnet is not deleted while it is still in use.
resource "time_sleep" "subnet_release" {
  destroy_duration = "180s"

  triggers = {
    subnet_id = var.subnet_id
  }
}

resource "databricks_private_network_gateway" "this" {
  provider = databricks.account

  parent                             = "accounts/${var.databricks_account_id}/network-connectivity-configs/${var.network_connectivity_config_id}"
  display_name                       = var.name
  traffic_mode                       = "SPECIFIC_DESTINATIONS"
  bandwidth_tier_gigabits_per_second = var.bandwidth_tier_gbps

  azure_cloud_connection = {
    gateway_subnet = {
      resource_id = time_sleep.subnet_release.triggers.subnet_id
    }
  }

  destinations = [
    for name in var.destinations : {
      destination_type = "DNS_NAME"
      value            = name
    }
  ]

  # Null rather than an empty list, so Azure-provided DNS shows no drift.
  private_dns_resolvers = length(var.private_dns_resolvers) == 0 ? null : [
    for address in var.private_dns_resolvers : {
      resolver_type = "IP_ADDRESS"
      value         = address
    }
  ]
}
