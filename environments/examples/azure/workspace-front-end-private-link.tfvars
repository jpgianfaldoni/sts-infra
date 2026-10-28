# Scenario: Workspace UI/API and browser authentication over front-end Private Link, tested from a VM
subscription_id = "00000000-0000-0000-0000-000000000000"
location        = "westus2"

features = {
  workspace = true
  test_vm   = true
}

# The databricks_ui_api endpoint is always created with the workspace.
workspace_front_end_private_link = {
  browser_authentication_enabled = true
  public_network_access_enabled  = false
}

workspace_network = {
  vnet_cidr                    = "10.130.0.0/16"
  host_subnet_cidr             = "10.130.0.0/24"
  container_subnet_cidr        = "10.130.1.0/24"
  private_endpoint_subnet_cidr = "10.130.2.0/26"
  dns_subnet_cidr              = "10.130.3.0/27"
  dns_server_ip                = "10.130.3.4"
  test_vm_subnet_cidr          = "10.130.4.0/27"
}

test_vm = {
  # Restrict this to the public IPv4 address from which you will run Azure CLI.
  allowed_ssh_source_cidr = "203.0.113.10/32"
  vm_size                 = "Standard_B2s"
  # Optional: paste ~/.ssh/id_ed25519.pub to allow direct SSH and disable passwords.
  # admin_ssh_public_key = "ssh-ed25519 AAAA... you@example.com"
}

tags = {
  ManagedBy   = "terraform"
  Environment = "demo"
  Owner       = "platform-team"
  Scenario    = "azure-front-end-private-link"
}

# Disposable lab: destroy may empty versioned buckets, lift database deletion
# protection, and skip final snapshots. Set false to keep data on destroy.
allow_destructive_demo_cleanup = true
