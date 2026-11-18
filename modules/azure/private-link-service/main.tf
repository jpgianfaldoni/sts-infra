resource "azurerm_lb" "this" {
  name                = "lb-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Standard"
  tags                = var.tags

  frontend_ip_configuration {
    name                          = "service"
    subnet_id                     = var.frontend_subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_lb_backend_address_pool" "this" {
  name            = "service"
  loadbalancer_id = azurerm_lb.this.id
}

resource "azurerm_network_interface_backend_address_pool_association" "this" {
  network_interface_id    = var.network_interface_id
  ip_configuration_name   = var.ip_configuration_name
  backend_address_pool_id = azurerm_lb_backend_address_pool.this.id
}

resource "azurerm_lb_probe" "this" {
  name            = "service"
  loadbalancer_id = azurerm_lb.this.id
  protocol        = "Tcp"
  port            = var.port
}

resource "azurerm_lb_rule" "this" {
  name                           = "service"
  loadbalancer_id                = azurerm_lb.this.id
  frontend_ip_configuration_name = "service"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.this.id]
  probe_id                       = azurerm_lb_probe.this.id
  protocol                       = "Tcp"
  frontend_port                  = var.port
  backend_port                   = var.port
  disable_outbound_snat          = true
  idle_timeout_in_minutes        = 30
  tcp_reset_enabled              = true
}

resource "azurerm_private_link_service" "this" {
  name                                        = "pls-${var.name}"
  location                                    = var.location
  resource_group_name                         = var.resource_group_name
  load_balancer_frontend_ip_configuration_ids = [azurerm_lb.this.frontend_ip_configuration[0].id]
  proxy_protocol_enabled                      = false
  # Other subscriptions may request a connection, but none is auto-approved.
  # ./infra approves only the endpoint name returned by this deployment's NCC.
  auto_approval_subscription_ids = []
  tags                           = var.tags

  nat_ip_configuration {
    name                       = "primary"
    subnet_id                  = var.nat_subnet_id
    private_ip_address_version = "IPv4"
    primary                    = true
  }

  depends_on = [azurerm_lb_rule.this, azurerm_network_interface_backend_address_pool_association.this]
}
