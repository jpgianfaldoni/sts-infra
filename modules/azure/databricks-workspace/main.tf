resource "azurerm_databricks_workspace" "this" {
  name                                  = var.workspace_name
  resource_group_name                   = var.resource_group_name
  location                              = var.location
  sku                                   = "premium"
  managed_resource_group_name           = "${var.resource_prefix}-managed-rg"
  public_network_access_enabled         = true
  network_security_group_rules_required = "NoAzureDatabricksRules"

  custom_parameters {
    no_public_ip                                         = true
    virtual_network_id                                   = var.vnet_id
    public_subnet_name                                   = var.host_subnet_name
    private_subnet_name                                  = var.container_subnet_name
    public_subnet_network_security_group_association_id  = var.host_nsg_association_id
    private_subnet_network_security_group_association_id = var.container_nsg_association_id
  }

  tags = var.tags
}

resource "azurerm_private_dns_zone" "databricks" {
  name                = "privatelink.azuredatabricks.net"
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "databricks" {
  name                  = "${var.resource_prefix}-dns-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.databricks.name
  virtual_network_id    = var.vnet_id
  tags                  = var.tags
}

resource "azurerm_private_endpoint" "backend" {
  name                = "${var.resource_prefix}-backend-pe"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "${var.resource_prefix}-backend-psc"
    private_connection_resource_id = azurerm_databricks_workspace.this.id
    subresource_names              = ["databricks_ui_api"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "databricks"
    private_dns_zone_ids = [azurerm_private_dns_zone.databricks.id]
  }
}
