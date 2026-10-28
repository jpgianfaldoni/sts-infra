output "local_to_remote_peering_id" {
  value = azurerm_virtual_network_peering.local_to_remote.id
}

output "remote_to_local_peering_id" {
  value = azurerm_virtual_network_peering.remote_to_local.id
}
