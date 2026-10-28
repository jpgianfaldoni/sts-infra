resource "random_password" "bootstrap" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+"
}

data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

resource "azurerm_public_ip" "this" {
  name                = "${var.resource_prefix}-test-vm-pip"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_security_group" "this" {
  name                = "${var.resource_prefix}-test-vm-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "AllowSshFromOperator"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.allowed_ssh_source_cidr
    destination_address_prefix = "*"
  }
}

resource "azapi_resource" "network_interface" {
  type      = "Microsoft.Network/networkInterfaces@2024-05-01"
  name      = "${var.resource_prefix}-test-vm-nic"
  parent_id = data.azurerm_resource_group.this.id
  location  = var.location
  tags      = var.tags

  body = {
    properties = {
      networkSecurityGroup = {
        id = azurerm_network_security_group.this.id
      }
      ipConfigurations = [{
        name = "primary"
        properties = {
          primary                   = true
          privateIPAllocationMethod = "Dynamic"
          privateIPAddressVersion   = "IPv4"
          subnet = {
            id = var.subnet_id
          }
          publicIPAddress = {
            id = azurerm_public_ip.this.id
          }
        }
      }]
    }
  }

  response_export_values = ["properties.ipConfigurations[0].properties.privateIPAddress"]
  depends_on             = [azurerm_subnet_network_security_group_association.this]
}

resource "azurerm_subnet_network_security_group_association" "this" {
  subnet_id                 = var.subnet_id
  network_security_group_id = azurerm_network_security_group.this.id
}

resource "azurerm_linux_virtual_machine" "this" {
  name                            = "${var.resource_prefix}-test-vm"
  computer_name                   = "fepltest"
  location                        = var.location
  resource_group_name             = var.resource_group_name
  size                            = var.vm_size
  admin_username                  = var.admin_username
  admin_password                  = var.admin_ssh_public_key == null ? random_password.bootstrap.result : null
  disable_password_authentication = var.admin_ssh_public_key != null
  network_interface_ids           = [azapi_resource.network_interface.id]
  secure_boot_enabled             = true
  vtpm_enabled                    = true
  tags                            = var.tags

  dynamic "admin_ssh_key" {
    for_each = var.admin_ssh_public_key == null ? [] : [trimspace(var.admin_ssh_public_key)]
    content {
      username   = var.admin_username
      public_key = admin_ssh_key.value
    }
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  custom_data = base64encode(<<-CLOUD_INIT
    #cloud-config
    package_update: true
    packages:
      - curl
      - dnsutils
      - jq
      - openssl
    CLOUD_INIT
  )

  boot_diagnostics {}

  identity {
    type = "SystemAssigned"
  }
}

resource "azapi_resource_action" "entra_ssh" {
  type        = "Microsoft.Compute/virtualMachines/extensions@2024-07-01"
  resource_id = "${azurerm_linux_virtual_machine.this.id}/extensions/AADSSHLoginForLinux"
  method      = "PUT"
  when        = "apply"

  body = {
    location = var.location
    tags     = var.tags
    properties = {
      publisher               = "Microsoft.Azure.ActiveDirectory"
      type                    = "AADSSHLoginForLinux"
      typeHandlerVersion      = "1.0"
      autoUpgradeMinorVersion = true
      forceUpdateTag          = "managed-identity-enabled-v1"
    }
  }
}

resource "azurerm_role_assignment" "admin_login" {
  scope                = azurerm_linux_virtual_machine.this.id
  role_definition_name = "Virtual Machine Administrator Login"
  principal_id         = var.admin_principal_object_id

  depends_on = [azapi_resource_action.entra_ssh]
}
