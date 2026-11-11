resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}
# Passwords avoid quotes and backslashes so the setup script can place them in
# SQL literals; it checks this before using them.
resource "random_password" "vm" {
  length           = 24
  special          = true
  override_special = "!#%*()-_=+"
  min_lower        = 1
  min_upper        = 1
  min_numeric      = 1
  min_special      = 1
}
resource "random_password" "mysql" {
  length           = 24
  special          = true
  override_special = "!#%*()-_=+"
  min_lower        = 1
  min_upper        = 1
  min_numeric      = 1
  min_special      = 1
}
resource "random_password" "lakeflow" {
  count            = var.lakeflow_connect_enabled ? 1 : 0
  length           = 24
  special          = true
  override_special = "!#%*()-_=+"
  min_lower        = 1
  min_upper        = 1
  min_numeric      = 1
  min_special      = 1
}
locals {
  name               = "${var.name_prefix}-${random_string.suffix.result}"
  database_name      = "demo"
  private_dns_labels = var.private_dns_name == null ? [] : split(".", var.private_dns_name)
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
resource "azurerm_subnet" "vm" {
  name                 = "snet-mysql-vm"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = var.vm_subnet_prefixes
}
# Outbound only, for the MySQL packages; nothing can reach the VM from outside.
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
    name                       = "AllowMySqlFromVirtualNetwork"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3306"
    source_address_prefix      = "VirtualNetwork"
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
resource "azurerm_linux_virtual_machine" "mysql" {
  name                            = "vm-${local.name}"
  computer_name                   = "mysql${random_string.suffix.result}"
  location                        = var.location
  resource_group_name             = azurerm_resource_group.this.name
  size                            = var.vm_size
  admin_username                  = var.vm_admin_username
  admin_password                  = random_password.vm.result
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.vm.id]
  secure_boot_enabled             = true
  vtpm_enabled                    = true
  tags                            = var.tags
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 64
  }
  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
  boot_diagnostics {
  }
  # NAT must exist before the VM's first boot so package installs can reach out.
  depends_on = [azurerm_subnet_nat_gateway_association.vm]
}

# Installs MySQL and prepares it for Lakeflow Connect from inside the VM
# through Azure VM Run Command, so setup needs no network path to MySQL.
resource "azurerm_virtual_machine_run_command" "setup" {
  name               = "mysql-setup"
  location           = var.location
  virtual_machine_id = azurerm_linux_virtual_machine.mysql.id
  tags               = var.tags

  source {
    script = templatefile("${path.module}/assets/mysql-setup.sh.tftpl", {
      database_name   = local.database_name
      lakeflow        = var.lakeflow_connect_enabled
      seed_sql_base64 = base64encode(file("${path.module}/assets/seed.sql"))
    })
  }
  parameter {
    name  = "MYSQL_ADMIN_USER"
    value = var.mysql_admin_username
  }
  parameter {
    name  = "LAKEFLOW_USER"
    value = "lakeflow"
  }
  protected_parameter {
    name  = "MYSQL_ADMIN_PASSWORD"
    value = random_password.mysql.result
  }
  protected_parameter {
    name  = "LAKEFLOW_PASSWORD"
    value = try(random_password.lakeflow[0].result, "unused")
  }
  timeouts {
    create = "45m"
    update = "45m"
  }
  lifecycle {
    postcondition {
      condition     = try(self.instance_view[0].exit_code, 1) == 0
      error_message = "MySQL setup failed on the VM. Read the LAKEFLOW_CDC_SETUP_FAILED line with: az vm run-command show --resource-group <rg> --vm-name <vm> --run-command-name mysql-setup --instance-view"
    }
  }
}

# Optional private hostname, resolved only inside this VNet.
resource "azurerm_private_dns_zone" "this" {
  count               = var.private_dns_name == null ? 0 : 1
  name                = join(".", slice(local.private_dns_labels, 1, length(local.private_dns_labels)))
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}
resource "azurerm_private_dns_a_record" "this" {
  count               = var.private_dns_name == null ? 0 : 1
  name                = local.private_dns_labels[0]
  zone_name           = azurerm_private_dns_zone.this[0].name
  resource_group_name = azurerm_resource_group.this.name
  ttl                 = 300
  records             = [var.vm_private_ip]
  tags                = var.tags
}
resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  count                 = var.private_dns_name == null ? 0 : 1
  name                  = "${local.name}-dns"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.this[0].name
  virtual_network_id    = azurerm_virtual_network.this.id
  registration_enabled  = false
  tags                  = var.tags
}
