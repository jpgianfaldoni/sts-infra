resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}
resource "random_password" "admin" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+"
}
locals {
  name                = "${var.name_prefix}-${random_string.suffix.result}"
  resource_group_name = coalesce(var.resource_group_name, "rg-${local.name}")
}
resource "azurerm_resource_group" "this" {
  name     = local.resource_group_name
  location = var.location
  tags     = var.tags
}
resource "azurerm_virtual_network" "this" {
  name                = "vnet-${local.name}"
  address_space       = var.vnet_address_space
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}
resource "azurerm_subnet" "private_endpoint" {
  name                              = "snet-private-endpoints"
  resource_group_name               = azurerm_resource_group.this.name
  virtual_network_name              = azurerm_virtual_network.this.name
  address_prefixes                  = var.private_endpoint_subnet_prefixes
  private_endpoint_network_policies = "Disabled"
}
resource "azurerm_private_dns_zone" "sql" {
  name                = "privatelink.database.windows.net"
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}
resource "azurerm_private_dns_zone_virtual_network_link" "sql" {
  name                  = "${local.name}-sql-dns"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.sql.name
  virtual_network_id    = azurerm_virtual_network.this.id
  tags                  = var.tags
}
resource "azurerm_mssql_server" "this" {
  name                          = "sql-${local.name}"
  resource_group_name           = azurerm_resource_group.this.name
  location                      = var.location
  version                       = "12.0"
  administrator_login           = var.admin_username
  administrator_login_password  = random_password.admin.result
  minimum_tls_version           = "1.2"
  public_network_access_enabled = false
  tags                          = var.tags
}
resource "azurerm_mssql_database" "this" {
  name                                = var.database_name
  server_id                           = azurerm_mssql_server.this.id
  sku_name                            = "Basic"
  max_size_gb                         = 2
  transparent_data_encryption_enabled = true
  tags                                = var.tags
}
resource "azurerm_private_endpoint" "sql" {
  name                = "pe-${local.name}-sql"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = azurerm_subnet.private_endpoint.id
  tags                = var.tags
  private_service_connection {
    name                           = "psc-${local.name}-sql"
    private_connection_resource_id = azurerm_mssql_server.this.id
    subresource_names              = ["sqlServer"]
    is_manual_connection           = false
  }
  private_dns_zone_group {
    name                 = "sql"
    private_dns_zone_ids = [azurerm_private_dns_zone.sql.id]
  }
}
