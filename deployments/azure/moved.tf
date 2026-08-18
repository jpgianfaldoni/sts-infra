# Preserve existing workspace network resources after extracting shared networking
# from the Databricks workspace module.
moved {
  from = module.workspace[0].azurerm_resource_group.this
  to   = module.workspace_network[0].azurerm_resource_group.this
}

moved {
  from = module.workspace[0].azurerm_virtual_network.this
  to   = module.workspace_network[0].azurerm_virtual_network.this
}

moved {
  from = module.workspace[0].azurerm_network_security_group.this
  to   = module.workspace_network[0].azurerm_network_security_group.databricks
}

moved {
  from = module.workspace[0].azurerm_subnet.host
  to   = module.workspace_network[0].azurerm_subnet.host
}

moved {
  from = module.workspace[0].azurerm_subnet.container
  to   = module.workspace_network[0].azurerm_subnet.container
}

moved {
  from = module.workspace[0].azurerm_subnet.private_endpoint
  to   = module.workspace_network[0].azurerm_subnet.private_endpoint
}

moved {
  from = module.workspace[0].azurerm_subnet_network_security_group_association.host
  to   = module.workspace_network[0].azurerm_subnet_network_security_group_association.host
}

moved {
  from = module.workspace[0].azurerm_subnet_network_security_group_association.container
  to   = module.workspace_network[0].azurerm_subnet_network_security_group_association.container
}

moved {
  from = module.workspace[0].azurerm_public_ip.nat
  to   = module.workspace_network[0].azurerm_public_ip.nat
}

moved {
  from = module.workspace[0].azurerm_nat_gateway.this
  to   = module.workspace_network[0].azurerm_nat_gateway.this
}

moved {
  from = module.workspace[0].azurerm_nat_gateway_public_ip_association.this
  to   = module.workspace_network[0].azurerm_nat_gateway_public_ip_association.this
}

moved {
  from = module.workspace[0].azurerm_subnet_nat_gateway_association.host
  to   = module.workspace_network[0].azurerm_subnet_nat_gateway_association.host
}

moved {
  from = module.workspace[0].azurerm_subnet_nat_gateway_association.container
  to   = module.workspace_network[0].azurerm_subnet_nat_gateway_association.container
}
