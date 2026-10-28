mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      client_id       = "55555555-5555-5555-5555-555555555555"
      object_id       = "66666666-6666-6666-6666-666666666666"
      tenant_id       = "11111111-1111-1111-1111-111111111111"
      subscription_id = "00000000-0000-0000-0000-000000000000"
    }
  }
}
mock_provider "azurerm" {
  alias = "storage_control_plane"
}
mock_provider "azapi" {}
mock_provider "databricks" {
  alias = "account"
  # Metastore lookups drive for_each, so mocked data must be known at plan.
  override_during = plan

  mock_data "databricks_metastores" {
    defaults = {
      ids = {}
    }
  }
}
mock_provider "databricks" {
  alias = "workspace"
}
mock_provider "random" {}
mock_provider "time" {}
mock_provider "azuread" {
  mock_data "azuread_service_principal" {
    defaults = {
      object_id = "77777777-7777-7777-7777-777777777777"
    }
  }
}

run "all_features_disabled" {
  command = plan
  variables {
    subscription_id       = "00000000-0000-0000-0000-000000000000"
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace               = false
      test_vm                 = false
      external_volume_storage = false
      custom_dns              = false
      sql_database            = false
      sql_server_vm           = false
    }
  }
  assert {
    condition     = output.workspace_url == null
    error_message = "The workspace must not be composed when its feature is disabled."
  }
  assert {
    condition     = output.workspace_id == null
    error_message = "The workspace ID output must be null when no workspace is managed."
  }
}

run "workspace_front_end_private_link_with_test_vm" {
  command = plan

  variables {
    subscription_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace = true
      test_vm   = true
    }
    workspace_front_end_private_link = {
      browser_authentication_enabled = true
      public_network_access_enabled  = false
    }
    test_vm = {
      allowed_ssh_source_cidr = "203.0.113.10/32"
    }
  }

  assert {
    condition     = var.workspace_front_end_private_link.public_network_access_enabled == false
    error_message = "The front-end Private Link scenario must support disabling public workspace access."
  }

  assert {
    condition     = output.workspace_front_end_private_link.browser_authentication_enabled == true
    error_message = "browser_authentication_enabled alone must create the browser SSO endpoint."
  }

  assert {
    condition     = output.test_vm.password_authentication_enabled == true
    error_message = "Without an SSH public key the test VM must keep today's password-based bootstrap."
  }

  assert {
    condition     = var.features.workspace && var.features.test_vm
    error_message = "The test VM must be composed with its default administrator username."
  }
}

run "deprecated_front_end_private_link_enabled_warns" {
  command = plan

  variables {
    subscription_id = "00000000-0000-0000-0000-000000000000"
    workspace_front_end_private_link = {
      enabled = true
    }
  }

  expect_failures = [check.front_end_private_link_enabled_deprecated]

  assert {
    condition     = output.workspace_front_end_private_link.browser_authentication_enabled == true
    error_message = "The deprecated enabled flag must keep creating the browser SSO endpoint until it is removed."
  }
}

run "browser_authentication_enabled_wins_over_deprecated_alias" {
  command = plan

  variables {
    subscription_id = "00000000-0000-0000-0000-000000000000"
    workspace_front_end_private_link = {
      enabled                        = true
      browser_authentication_enabled = false
    }
  }

  expect_failures = [check.front_end_private_link_enabled_deprecated]

  assert {
    condition     = output.workspace_front_end_private_link.browser_authentication_enabled == false
    error_message = "browser_authentication_enabled must take precedence over the deprecated enabled flag."
  }
}

run "warn_when_public_access_disabled_without_browser_sso" {
  command = plan

  variables {
    subscription_id = "00000000-0000-0000-0000-000000000000"
    workspace_front_end_private_link = {
      public_network_access_enabled = false
    }
  }

  expect_failures = [check.browser_sso_without_public_access]
}

run "reject_test_vm_without_workspace" {
  command = plan

  variables {
    subscription_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace = false
      test_vm   = true
    }
    test_vm = {
      allowed_ssh_source_cidr = "203.0.113.10/32"
    }
  }

  expect_failures = [var.features]
}

run "workspace_with_external_volume_storage" {
  command = plan

  variables {
    subscription_id       = "00000000-0000-0000-0000-000000000000"
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace               = true
      external_volume_storage = true
      custom_dns              = false
      sql_database            = false
      sql_server_vm           = false
    }
    external_volume_storage = {
      public_network_access_enabled = false
      allow_unreachable_storage     = true
    }
  }

  assert {
    condition     = output.external_volume_storage.public_network_access_enabled == false
    error_message = "External volume storage must support disabling its public endpoint without adding private connectivity."
  }

  assert {
    condition     = output.external_volume_storage.connectivity_status == "metadata_only"
    error_message = "Locked-down storage without private connectivity must be identified as metadata-only."
  }
}

run "warn_when_workspace_api_unreachable_from_operator" {
  command = plan

  variables {
    subscription_id       = "00000000-0000-0000-0000-000000000000"
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace               = true
      external_volume_storage = true
    }
    workspace_front_end_private_link = {
      browser_authentication_enabled = true
      public_network_access_enabled  = false
    }
    external_volume_storage = {
      public_network_access_enabled = false
      allow_unreachable_storage     = true
    }
  }

  expect_failures = [check.workspace_api_reachable_from_operator]
}

run "reject_invalid_tenant_id" {
  command = plan

  variables {
    subscription_id = "00000000-0000-0000-0000-000000000000"
    tenant_id       = "not-a-tenant"
    features = {
      workspace = false
    }
  }

  expect_failures = [var.tenant_id]
}

run "reject_external_volume_storage_without_workspace" {
  command = plan

  variables {
    subscription_id       = "00000000-0000-0000-0000-000000000000"
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace               = false
      external_volume_storage = true
    }
  }

  expect_failures = [var.features]
}

run "reuse_existing_metastore" {
  command = plan

  variables {
    subscription_id       = "00000000-0000-0000-0000-000000000000"
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace               = true
      external_volume_storage = true
    }
    external_volume_storage = {
      public_network_access_enabled = true
      metastore_mode                = "existing"
      metastore_id                  = "11111111-1111-1111-1111-111111111111"
    }
  }

  assert {
    condition     = output.external_volume_storage.metastore_mode == "existing"
    error_message = "Existing metastore mode must be reported in the deployment output."
  }

  assert {
    condition     = output.external_volume_storage.metastore_id == "11111111-1111-1111-1111-111111111111"
    error_message = "Existing metastore mode must use the configured metastore ID."
  }
}

run "reject_existing_metastore_without_id" {
  command = plan

  variables {
    subscription_id       = "00000000-0000-0000-0000-000000000000"
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    external_volume_storage = {
      metastore_mode = "existing"
    }
  }

  expect_failures = [var.external_volume_storage]
}

run "reject_unreachable_storage_without_acknowledgement" {
  command = plan

  variables {
    subscription_id       = "00000000-0000-0000-0000-000000000000"
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace               = true
      external_volume_storage = true
    }
    external_volume_storage = {
      public_network_access_enabled = false
      allow_unreachable_storage     = false
    }
  }

  expect_failures = [var.external_volume_storage]
}

run "temporary_seed_access" {
  command = plan

  variables {
    subscription_id       = "00000000-0000-0000-0000-000000000000"
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace               = true
      external_volume_storage = true
    }
    external_volume_storage = {
      public_network_access_enabled = false
      allow_unreachable_storage     = true
    }
    external_volume_bootstrap_access_enabled = true
    external_volume_bootstrap_operator_cidr  = "203.0.113.10/32"
  }

  assert {
    condition     = output.external_volume_storage.public_network_access_enabled == true
    error_message = "Bootstrap mode must temporarily enable the storage public endpoint."
  }

  assert {
    condition     = output.external_volume_storage.bootstrap_access_enabled == true
    error_message = "Bootstrap mode must be exposed in the deployment output."
  }

  assert {
    condition     = output.external_volume_storage.connectivity_status == "bootstrap"
    error_message = "Bootstrap connectivity must be distinguishable from final public or metadata-only connectivity."
  }
}

run "names_default_without_deployment_id" {
  command = plan

  variables {
    subscription_id = "00000000-0000-0000-0000-000000000000"
  }

  assert {
    condition     = module.workspace_network[0].resource_group_name == "demo-workspace-rg"
    error_message = "Without a deployment ID or name_prefix, names must keep the historical demo prefix."
  }
}

run "names_derive_from_deployment_id" {
  command = plan

  variables {
    subscription_id = "00000000-0000-0000-0000-000000000000"
    deployment_id   = "My_Lab.01"
  }

  assert {
    condition     = module.workspace_network[0].resource_group_name == "my-lab-01-workspace-rg"
    error_message = "Unset name_prefix must derive from the sanitized deployment ID."
  }
}

run "explicit_name_prefix_wins" {
  command = plan

  variables {
    subscription_id = "00000000-0000-0000-0000-000000000000"
    deployment_id   = "my-lab"
    name_prefix     = "explicit"
  }

  assert {
    condition     = module.workspace_network[0].resource_group_name == "explicit-workspace-rg"
    error_message = "An explicit name_prefix must win over the deployment ID."
  }
}

run "reject_invalid_deployment_id" {
  command = plan

  variables {
    subscription_id = "00000000-0000-0000-0000-000000000000"
    deployment_id   = "-bad id"
  }

  expect_failures = [var.deployment_id]
}

run "test_vm_with_ssh_key" {
  command = plan

  variables {
    subscription_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace = true
      test_vm   = true
    }
    test_vm = {
      allowed_ssh_source_cidr = "203.0.113.10/32"
      admin_ssh_public_key    = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGrMhFV4S+ybb2wWEDVnHdWtJ8c4QT5QMcoQES3kvaFS sts-infra-test"
    }
  }

  assert {
    condition     = output.test_vm.password_authentication_enabled == false
    error_message = "An SSH public key must disable password authentication."
  }
}

run "reject_invalid_ssh_key" {
  command = plan

  variables {
    subscription_id = "00000000-0000-0000-0000-000000000000"
    test_vm = {
      admin_ssh_public_key = "not-a-key"
    }
  }

  expect_failures = [var.test_vm]
}

run "metastore_auto_creates_when_region_has_none" {
  command = plan

  variables {
    subscription_id       = "00000000-0000-0000-0000-000000000000"
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace               = true
      external_volume_storage = true
    }
    external_volume_storage = {
      public_network_access_enabled = true
      metastore_mode                = "auto"
    }
  }

  override_data {
    target          = module.external_volume_storage[0].data.databricks_metastores.all[0]
    override_during = plan
    values = {
      ids = {
        "shared-eastus" = "33333333-3333-3333-3333-333333333333"
      }
    }
  }

  override_data {
    target          = module.external_volume_storage[0].data.databricks_metastore.candidate["shared-eastus"]
    override_during = plan
    values = {
      metastore_id = "33333333-3333-3333-3333-333333333333"
      region       = "eastus"
    }
  }

  assert {
    condition     = output.external_volume_storage.metastore_created == true && output.external_volume_storage.metastore_resolution == "create"
    error_message = "Auto mode must create a metastore when the region has none."
  }
}

run "metastore_auto_reuses_the_only_regional_metastore" {
  command = plan

  variables {
    subscription_id       = "00000000-0000-0000-0000-000000000000"
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace               = true
      external_volume_storage = true
    }
    external_volume_storage = {
      public_network_access_enabled = true
      metastore_mode                = "auto"
    }
  }

  override_data {
    target          = module.external_volume_storage[0].data.databricks_metastores.all[0]
    override_during = plan
    values = {
      ids = {
        "shared-westus2" = "22222222-2222-2222-2222-222222222222"
        "shared-eastus"  = "33333333-3333-3333-3333-333333333333"
      }
    }
  }

  override_data {
    target          = module.external_volume_storage[0].data.databricks_metastore.candidate["shared-westus2"]
    override_during = plan
    values = {
      metastore_id = "22222222-2222-2222-2222-222222222222"
      region       = "westus2"
    }
  }

  override_data {
    target          = module.external_volume_storage[0].data.databricks_metastore.candidate["shared-eastus"]
    override_during = plan
    values = {
      metastore_id = "33333333-3333-3333-3333-333333333333"
      region       = "eastus"
    }
  }

  assert {
    condition     = output.external_volume_storage.metastore_created == false && output.external_volume_storage.metastore_resolution == "reuse"
    error_message = "Auto mode must not create a metastore when the region has exactly one other."
  }

  assert {
    condition     = output.external_volume_storage.metastore_id == "22222222-2222-2222-2222-222222222222"
    error_message = "Auto mode must assign the only metastore in the workspace region."
  }
}

run "metastore_auto_keeps_its_managed_metastore" {
  command = plan

  variables {
    subscription_id       = "00000000-0000-0000-0000-000000000000"
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace               = true
      external_volume_storage = true
    }
    external_volume_storage = {
      public_network_access_enabled = true
      metastore_mode                = "auto"
    }
  }

  override_data {
    target          = module.external_volume_storage[0].data.databricks_metastores.all[0]
    override_during = plan
    values = {
      ids = {
        "demo-metastore" = "44444444-4444-4444-4444-444444444444"
        "shared-westus2" = "22222222-2222-2222-2222-222222222222"
      }
    }
  }

  override_data {
    target          = module.external_volume_storage[0].data.databricks_metastore.candidate["demo-metastore"]
    override_during = plan
    values = {
      metastore_id = "44444444-4444-4444-4444-444444444444"
      region       = "westus2"
    }
  }

  override_data {
    target          = module.external_volume_storage[0].data.databricks_metastore.candidate["shared-westus2"]
    override_during = plan
    values = {
      metastore_id = "22222222-2222-2222-2222-222222222222"
      region       = "westus2"
    }
  }

  assert {
    condition     = output.external_volume_storage.metastore_created == true && output.external_volume_storage.metastore_resolution == "create"
    error_message = "Auto mode must keep managing the metastore it created instead of switching to another."
  }
}

run "metastore_auto_rejects_ambiguous_region" {
  command = plan

  variables {
    subscription_id       = "00000000-0000-0000-0000-000000000000"
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace               = true
      external_volume_storage = true
    }
    external_volume_storage = {
      public_network_access_enabled = true
      metastore_mode                = "auto"
    }
  }

  override_data {
    target          = module.external_volume_storage[0].data.databricks_metastores.all[0]
    override_during = plan
    values = {
      ids = {
        "team-a-westus2" = "22222222-2222-2222-2222-222222222222"
        "team-b-westus2" = "33333333-3333-3333-3333-333333333333"
      }
    }
  }

  override_data {
    target          = module.external_volume_storage[0].data.databricks_metastore.candidate["team-a-westus2"]
    override_during = plan
    values = {
      metastore_id = "22222222-2222-2222-2222-222222222222"
      region       = "westus2"
    }
  }

  override_data {
    target          = module.external_volume_storage[0].data.databricks_metastore.candidate["team-b-westus2"]
    override_during = plan
    values = {
      metastore_id = "33333333-3333-3333-3333-333333333333"
      region       = "West US 2"
    }
  }

  expect_failures = [output.external_volume_storage]
}

run "sql_database_with_key_vault_and_entra_admin" {
  command = plan

  variables {
    subscription_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace    = false
      sql_database = true
    }
  }

  assert {
    condition     = output.key_vault.secret_names == tolist(["sql-database-admin-username", "sql-database-admin-password"])
    error_message = "The SQL credentials must be stored in Key Vault by default."
  }

  assert {
    condition     = output.key_vault.databricks_secret_scope == null
    error_message = "No secret scope can be created without a workspace."
  }

  assert {
    condition     = output.sql_database.entra_admin_object_id != null
    error_message = "The deploying principal must become the SQL Entra administrator by default."
  }

  assert {
    condition     = output.sql_database.password_secret_name == "sql-database-admin-password"
    error_message = "The SQL output must name the Key Vault secret holding the password."
  }
}

run "key_vault_backed_secret_scope_with_workspace" {
  command = plan

  variables {
    subscription_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = true
      sql_database  = true
      sql_server_vm = true
    }
  }

  assert {
    condition     = output.key_vault.databricks_secret_scope == "sts-infra"
    error_message = "A Key Vault-backed secret scope must be created when the workspace exists."
  }

  assert {
    condition     = length(output.key_vault.secret_names) == 6
    error_message = "SQL Database and SQL Server VM credentials must all be stored."
  }
}

run "key_vault_and_entra_admin_can_be_disabled" {
  command = plan

  variables {
    subscription_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace    = false
      sql_database = true
    }
    key_vault = {
      enabled = false
    }
    sql_database = {
      entra_admin_enabled = false
    }
  }

  assert {
    condition     = output.key_vault == null && output.sql_database.password_secret_name == null
    error_message = "Disabling the Key Vault must remove it and its secret references."
  }

  assert {
    condition     = output.sql_database.entra_admin_object_id == null
    error_message = "Disabling the Entra administrator must leave SQL authentication only."
  }
}

run "sql_database_workspace_peering" {
  command = plan

  variables {
    subscription_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace    = true
      sql_database = true
    }
    sql_database = {
      workspace_peering_enabled = true
    }
  }

  assert {
    condition     = length(module.sql_database_workspace_peering) == 1 && output.sql_database.workspace_peering_enabled
    error_message = "Opt-in peering must connect the SQL VNet to the workspace VNet."
  }
}

run "sql_database_without_peering_by_default" {
  command = plan

  variables {
    subscription_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace    = true
      sql_database = true
    }
  }

  assert {
    condition     = length(module.sql_database_workspace_peering) == 0
    error_message = "Peering must stay off unless requested."
  }

  assert {
    condition     = output.pending_endpoint_approvals == [] && output.serverless_connectivity == null
    error_message = "Without serverless Private Link there must be no NCC or pending approvals."
  }
}

run "reject_sql_peering_without_workspace" {
  command = plan

  variables {
    subscription_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace    = false
      sql_database = true
    }
    sql_database = {
      workspace_peering_enabled = true
    }
  }

  expect_failures = [var.sql_database]
}

run "reject_overlapping_sql_peering_cidrs" {
  command = plan

  variables {
    subscription_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace    = true
      sql_database = true
    }
    sql_database = {
      workspace_peering_enabled = true
    }
    sql_database_network = {
      vnet_address_space               = ["10.70.128.0/17"]
      private_endpoint_subnet_prefixes = ["10.70.129.0/24"]
    }
  }

  expect_failures = [var.sql_database]
}

run "serverless_private_link_to_sql_database" {
  command = plan

  variables {
    subscription_id       = "00000000-0000-0000-0000-000000000000"
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace    = true
      sql_database = true
    }
    connectivity = {
      sql_database = {
        serverless = "private_link"
      }
    }
  }

  assert {
    condition     = length(module.ncc) == 1
    error_message = "Serverless Private Link must create an NCC with a private endpoint rule."
  }
}

run "reject_serverless_private_link_without_account" {
  command = plan

  variables {
    subscription_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace    = true
      sql_database = true
    }
    connectivity = {
      sql_database = {
        serverless = "private_link"
      }
    }
  }

  expect_failures = [var.connectivity]
}

run "reject_unknown_serverless_mode" {
  command = plan

  variables {
    subscription_id = "00000000-0000-0000-0000-000000000000"
    connectivity = {
      sql_database = {
        serverless = "peering"
      }
    }
  }

  expect_failures = [var.connectivity]
}

run "lab_check_seeds_sql_over_serverless_private_link" {
  command = plan

  variables {
    subscription_id       = "00000000-0000-0000-0000-000000000000"
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace    = true
      sql_database = true
    }
    connectivity = {
      sql_database = {
        serverless = "private_link"
      }
    }
  }

  assert {
    condition     = keys(output.lab_check.checks) == ["sql_database_serverless"]
    error_message = "Only the serverless path is configured, so only it is checked."
  }

  assert {
    condition = (
      output.lab_check.checks.sql_database_serverless.engine == "sqlserver" &&
      output.lab_check.checks.sql_database_serverless.seeded &&
      output.lab_check.secret_scope == "sts-infra"
    )
    error_message = "The Azure SQL check must load the sample data with the Key Vault-backed credentials."
  }
}

run "lab_check_classic_peering_then_serverless" {
  command = plan

  variables {
    subscription_id       = "00000000-0000-0000-0000-000000000000"
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace    = true
      sql_database = true
    }
    connectivity = {
      sql_database = {
        serverless = "private_link"
      }
    }
    sql_database = {
      workspace_peering_enabled = true
    }
  }

  assert {
    condition     = output.lab_check.checks.sql_database_classic.mode == "peering"
    error_message = "VNet peering is the classic path to Azure SQL."
  }

  assert {
    condition     = output.lab_check.checks.sql_database_serverless.run_after == "sql_database_classic"
    error_message = "The serverless check must run after the classic one."
  }
}

run "lab_check_without_secret_scope_tests_tcp_only" {
  command = plan

  variables {
    subscription_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace    = true
      sql_database = true
    }
    sql_database = {
      workspace_peering_enabled = true
    }
    key_vault = {
      databricks_secret_scope_enabled = false
    }
  }

  assert {
    condition     = output.lab_check.checks.sql_database_classic.engine == "tcp" && !output.lab_check.checks.sql_database_classic.seeded
    error_message = "Without credentials the check can only test TCP reachability."
  }
}

run "no_lab_check_for_disconnected_sql" {
  command = plan

  variables {
    subscription_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace    = true
      sql_database = true
    }
  }

  assert {
    condition     = output.lab_check == null
    error_message = "A disconnected Azure SQL database has nothing to check."
  }
}

run "reject_unknown_azure_endpoint_approval" {
  command = plan

  variables {
    subscription_id   = "00000000-0000-0000-0000-000000000000"
    endpoint_approval = "later"
  }

  expect_failures = [var.endpoint_approval]
}
