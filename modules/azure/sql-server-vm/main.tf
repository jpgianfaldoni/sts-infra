resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}
resource "random_password" "vm" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+"
}
resource "random_password" "sql" {
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
resource "azurerm_subnet" "vm" {
  name                 = "snet-sql-vm"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = var.vm_subnet_prefixes
}
resource "azurerm_subnet" "private_link_service" {
  name                                          = "snet-private-link-service"
  resource_group_name                           = azurerm_resource_group.this.name
  virtual_network_name                          = azurerm_virtual_network.this.name
  address_prefixes                              = var.private_link_service_subnet_prefixes
  private_link_service_network_policies_enabled = false
}
resource "azurerm_public_ip" "nat" {
  name                = "pip-${local.name}-nat"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}
resource "azurerm_nat_gateway" "this" {
  name                = "nat-${local.name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  sku_name            = "Standard"
  tags                = var.tags
}
resource "azurerm_nat_gateway_public_ip_association" "this" {
  nat_gateway_id       = azurerm_nat_gateway.this.id
  public_ip_address_id = azurerm_public_ip.nat.id
}
resource "azurerm_subnet_nat_gateway_association" "vm" {
  subnet_id      = azurerm_subnet.vm.id
  nat_gateway_id = azurerm_nat_gateway.this.id
}
resource "azurerm_network_security_group" "vm" {
  name                = "nsg-${local.name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
  security_rule {
    name                       = "AllowSqlFromPrivateLinkService"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "1433"
    source_address_prefix      = azurerm_subnet.private_link_service.address_prefixes[0]
    destination_address_prefix = var.vm_private_ip
  }
  security_rule {
    name                       = "AllowAzureLoadBalancerProbe"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "1433"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = var.vm_private_ip
  }
}
resource "azurerm_network_interface" "vm" {
  name                = "nic-${local.name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.vm_private_ip
  }
}
resource "azurerm_network_interface_security_group_association" "vm" {
  network_interface_id      = azurerm_network_interface.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}
resource "azurerm_windows_virtual_machine" "sql" {
  name                  = "vm-${local.name}"
  computer_name         = "sql${random_string.suffix.result}"
  location              = var.location
  resource_group_name   = azurerm_resource_group.this.name
  size                  = var.vm_size
  admin_username        = var.vm_admin_username
  admin_password        = random_password.vm.result
  network_interface_ids = [azurerm_network_interface.vm.id]
  secure_boot_enabled   = true
  vtpm_enabled          = true
  tags                  = var.tags
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 128
  }
  source_image_reference {
    publisher = "MicrosoftSQLServer"
    offer     = "sql2022-ws2022"
    sku       = "sqldev-gen2"
    version   = "latest"
  }
  boot_diagnostics {
  }
}
resource "azurerm_mssql_virtual_machine" "sql" {
  virtual_machine_id               = azurerm_windows_virtual_machine.sql.id
  sql_license_type                 = "PAYG"
  sql_connectivity_type            = "PRIVATE"
  sql_connectivity_port            = 1433
  sql_connectivity_update_username = var.sql_admin_username
  sql_connectivity_update_password = random_password.sql.result
  tags                             = var.tags
}
