resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}
resource "random_password" "admin" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+"
  min_lower        = 1
  min_upper        = 1
  min_numeric      = 1
  min_special      = 1
}
locals {
  name = "${var.name_prefix}-${random_string.suffix.result}"
}
resource "azurerm_resource_group" "this" {
  name     = "rg-${local.name}"
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
resource "azurerm_private_dns_zone" "mysql" {
  name                = "privatelink.mysql.database.azure.com"
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}
resource "azurerm_private_dns_zone_virtual_network_link" "mysql" {
  name                  = "${local.name}-mysql-dns"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.mysql.name
  virtual_network_id    = azurerm_virtual_network.this.id
  tags                  = var.tags
}

# Public access is disabled; the server is reached through private endpoints
# only (this VNet's, and the NCC's for serverless compute).
resource "azurerm_mysql_flexible_server" "this" {
  name                   = "mysql-${local.name}"
  resource_group_name    = azurerm_resource_group.this.name
  location               = var.location
  version                = var.mysql_version
  sku_name               = var.sku_name
  administrator_login    = var.admin_username
  administrator_password = random_password.admin.result
  backup_retention_days  = 7
  public_network_access  = "Disabled"
  tags                   = var.tags

  storage {
    size_gb           = 20
    auto_grow_enabled = true
  }

  # Azure picks an availability zone when none is set; keep it on later plans.
  lifecycle {
    ignore_changes = [zone]
  }
}
resource "azurerm_mysql_flexible_database" "this" {
  name                = var.database_name
  resource_group_name = azurerm_resource_group.this.name
  server_name         = azurerm_mysql_flexible_server.this.name
  charset             = "utf8mb4"
  collation           = "utf8mb4_0900_ai_ci"
}

# Lakeflow Connect reads row-based binary logs with full row images.
# Flexible Server always logs in ROW format; retention defaults to zero.
resource "azurerm_mysql_flexible_server_configuration" "binlog" {
  for_each = var.lakeflow_connect_enabled ? {
    binlog_row_image           = "FULL"
    binlog_expire_logs_seconds = "604800"
  } : {}

  name                = each.key
  resource_group_name = azurerm_resource_group.this.name
  server_name         = azurerm_mysql_flexible_server.this.name
  value               = each.value
}
resource "azurerm_private_endpoint" "mysql" {
  name                = "pe-${local.name}-mysql"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = azurerm_subnet.private_endpoint.id
  tags                = var.tags
  private_service_connection {
    name                           = "psc-${local.name}-mysql"
    private_connection_resource_id = azurerm_mysql_flexible_server.this.id
    subresource_names              = ["mysqlServer"]
    is_manual_connection           = false
  }
  private_dns_zone_group {
    name                 = "mysql"
    private_dns_zone_ids = [azurerm_private_dns_zone.mysql.id]
  }
}

# Lakeflow Connect replication user; the lab check job creates it.
resource "random_password" "lakeflow" {
  count            = var.lakeflow_connect_enabled ? 1 : 0
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+"
  min_lower        = 1
  min_upper        = 1
  min_numeric      = 1
  min_special      = 1
}
