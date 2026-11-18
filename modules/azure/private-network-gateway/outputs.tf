output "name" {
  description = "Canonical resource name: accounts/<account>/network-connectivity-configs/<ncc>/private-network-gateways/<gateway>."
  value       = databricks_private_network_gateway.this.name
}

output "state" {
  value = databricks_private_network_gateway.this.state
}

output "destinations" {
  value = var.destinations
}
