resource "random_password" "admin" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+"
}

resource "azurerm_network_security_group" "this" {
  name                = "${var.resource_prefix}-dns-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "AllowDnsFromVnet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "53"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = var.private_ip
  }

  security_rule {
    name                       = "DenyOtherVnetInbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = var.private_ip
  }
}

resource "azurerm_network_interface" "this" {
  name                = "${var.resource_prefix}-dns-nic"
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_servers         = ["168.63.129.16"]
  tags                = var.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.private_ip
  }
}

resource "azurerm_network_interface_security_group_association" "this" {
  network_interface_id      = azurerm_network_interface.this.id
  network_security_group_id = azurerm_network_security_group.this.id
}

resource "azurerm_linux_virtual_machine" "this" {
  name                            = "${var.resource_prefix}-dns-vm"
  computer_name                   = "dnsforwarder"
  location                        = var.location
  resource_group_name             = var.resource_group_name
  size                            = var.vm_size
  admin_username                  = var.admin_username
  admin_password                  = random_password.admin.result
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.this.id]
  secure_boot_enabled             = true
  vtpm_enabled                    = true
  tags                            = var.tags

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
      - bind9
      - dnsutils
    write_files:
      - path: /etc/bind/named.conf.options
        owner: root:bind
        permissions: '0644'
        defer: true
        content: |
          options {
            directory "/var/cache/bind";
            recursion yes;
            allow-query { any; };
            listen-on { any; };
            listen-on-v6 { none; };
            forward only;
            forwarders { 168.63.129.16; };
            dnssec-validation auto;
          };
    runcmd:
      - named-checkconf
      - systemctl enable --now named
      - systemctl restart named
      - test -n "$(dig +short @127.0.0.1 management.azure.com)"
    CLOUD_INIT
  )

  boot_diagnostics {}
}

resource "azurerm_virtual_machine_extension" "verify_dns" {
  name                       = "verify-dns-forwarder"
  virtual_machine_id         = azurerm_linux_virtual_machine.this.id
  publisher                  = "Microsoft.Azure.Extensions"
  type                       = "CustomScript"
  type_handler_version       = "2.1"
  auto_upgrade_minor_version = true
  settings = jsonencode({
    commandToExecute = "cloud-init status --wait && systemctl is-active --quiet named && test -n \"$(dig +short @${var.private_ip} management.azure.com)\""
  })
  tags = var.tags
}
