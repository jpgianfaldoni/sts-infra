variable "subscription_id" {
  type = string
}
variable "tenant_id" {
  description = "Optional Microsoft Entra tenant ID. ./infra supplies the tenant of the selected subscription so every provider uses the same tenant."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.tenant_id == null || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.tenant_id))
    error_message = "tenant_id must be null or an Entra tenant UUID."
  }
}
variable "databricks_auth_type" {
  description = "Optional Databricks auth type for providers without a profile. ./infra sets azure-cli for local Azure CLI sessions; automation can leave it null and use provider environment variables."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.databricks_auth_type == null || trimspace(var.databricks_auth_type) != ""
    error_message = "databricks_auth_type must be null or a non-empty Databricks auth type."
  }
}
variable "location" {
  type    = string
  default = "westus2"
}
variable "deployment_id" {
  description = "Deployment ID supplied by ./infra. Names derive from it when name_prefix or workspace_name is unset."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.deployment_id == null || can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", var.deployment_id))
    error_message = "deployment_id must match [A-Za-z0-9][A-Za-z0-9._-]{0,127}."
  }
}
variable "name_prefix" {
  description = "Prefix for Azure resource names. Defaults to the sanitized deployment ID, or \"demo\" without one."
  type        = string
  default     = null
  nullable    = true
}
variable "workspace_name" {
  description = "Azure Databricks workspace name. Defaults to the sanitized deployment ID, or \"demo-azure-classic\" without one."
  type        = string
  default     = null
  nullable    = true
}
variable "databricks_account_id" {
  description = "Azure Databricks account ID used for account-level Unity Catalog resources."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = !var.features.external_volume_storage || var.databricks_account_id != null
    error_message = "databricks_account_id is required when features.external_volume_storage is enabled."
  }

  validation {
    condition     = var.databricks_account_id == null || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.databricks_account_id))
    error_message = "databricks_account_id must be null or a Databricks account UUID."
  }
}
variable "databricks_account_profile" {
  description = "Optional local Azure Databricks account profile. Automation can use standard Databricks provider environment variables instead."
  type        = string
  default     = null
  nullable    = true
}
variable "databricks_workspace_profile" {
  description = "Optional local Databricks workspace profile. When omitted, the provider uses Azure CLI authentication."
  type        = string
  default     = null
  nullable    = true
}
variable "features" {
  type = object({
    workspace               = optional(bool, true)
    test_vm                 = optional(bool, false)
    external_volume_storage = optional(bool, false)
    custom_dns              = optional(bool, false)
    sql_database            = optional(bool, false)
    sql_server_vm           = optional(bool, false)
  })
  default = {
  }

  validation {
    condition = (
      (!var.features.custom_dns || var.features.workspace) &&
      (!var.features.test_vm || var.features.workspace) &&
      (!var.features.external_volume_storage || var.features.workspace)
    )
    error_message = "features.custom_dns, features.test_vm, and features.external_volume_storage require features.workspace to be enabled."
  }
}

variable "workspace_front_end_private_link" {
  description = "Inbound workspace access. The databricks_ui_api private endpoint is always created with the workspace; browser_authentication_enabled adds the browser SSO endpoint."
  type = object({
    # Deprecated alias for browser_authentication_enabled, used only when that
    # attribute is unset; removed in the next release. It never controlled the
    # databricks_ui_api endpoint, which always exists.
    enabled                        = optional(bool)
    browser_authentication_enabled = optional(bool)
    public_network_access_enabled  = optional(bool, true)
  })
  default = {}
}

variable "test_vm" {
  description = "Accessible Linux test host used to verify private DNS and the workspace front-end networking path."
  type = object({
    allowed_ssh_source_cidr = optional(string)
    admin_username          = optional(string, "azureuser")
    vm_size                 = optional(string, "Standard_B2s")
    # Optional OpenSSH public key. When set, password authentication is disabled.
    admin_ssh_public_key = optional(string)
  })
  default = {}

  validation {
    condition = (
      !var.features.test_vm ||
      try(cidrhost(var.test_vm.allowed_ssh_source_cidr, 0) != "", false)
    )
    error_message = "test_vm.allowed_ssh_source_cidr must be a valid CIDR when features.test_vm is enabled."
  }

  validation {
    condition = (
      var.test_vm.admin_ssh_public_key == null ||
      can(regex("^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\\.com) [A-Za-z0-9+/=]+", trimspace(var.test_vm.admin_ssh_public_key)))
    )
    error_message = "test_vm.admin_ssh_public_key must be an OpenSSH public key (for example the contents of ~/.ssh/id_ed25519.pub)."
  }
}
variable "external_volume_storage" {
  description = "Azure storage and Unity Catalog external volume configuration."
  type = object({
    public_network_access_enabled = optional(bool, false)
    allow_unreachable_storage     = optional(bool, false)
    container_name                = optional(string, "external-volume")
    catalog_name                  = optional(string, "azure_storage_demo")
    schema_name                   = optional(string, "demo")
    volume_name                   = optional(string, "private_json")
    volume_storage_path           = optional(string, "volume")
    metastore_mode                = optional(string, "create")
    metastore_id                  = optional(string)
    allow_force_destroy           = optional(bool, false)
  })
  default = {}

  validation {
    condition     = contains(["create", "existing", "auto"], var.external_volume_storage.metastore_mode)
    error_message = "external_volume_storage.metastore_mode must be create, existing, or auto (reuse the account's metastore in the workspace region, else create one)."
  }

  validation {
    condition = (
      var.external_volume_storage.metastore_mode != "existing" ||
      try(length(var.external_volume_storage.metastore_id) > 0, false)
    )
    error_message = "external_volume_storage.metastore_id is required when metastore_mode is existing."
  }

  validation {
    condition = (
      !var.features.external_volume_storage ||
      var.external_volume_storage.public_network_access_enabled ||
      var.external_volume_storage.allow_unreachable_storage
    )
    error_message = "Storage without a public endpoint or private connectivity is metadata-only; set external_volume_storage.allow_unreachable_storage = true to acknowledge it."
  }

  validation {
    condition     = trim(var.external_volume_storage.volume_storage_path, "/") != "catalog-managed"
    error_message = "external_volume_storage.volume_storage_path must differ from the reserved catalog-managed prefix."
  }
}

variable "external_volume_bootstrap_access_enabled" {
  description = "Ephemeral CLI override used only by ./infra seed-access-plan. Do not set in committed tfvars."
  type        = bool
  default     = false
}

variable "external_volume_bootstrap_operator_cidr" {
  description = "Ephemeral operator CIDR used only while seed access is enabled."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = (
      !var.external_volume_bootstrap_access_enabled ||
      can(cidrhost(var.external_volume_bootstrap_operator_cidr, 0))
    )
    error_message = "external_volume_bootstrap_operator_cidr must be a valid CIDR when bootstrap access is enabled."
  }
}
variable "workspace_network" {
  type = object({ vnet_cidr = string
    host_subnet_cidr             = string
    container_subnet_cidr        = string
    private_endpoint_subnet_cidr = string
    test_vm_subnet_cidr          = optional(string, "10.70.4.0/27")
    dns_subnet_cidr              = optional(string, "10.70.3.0/27")
    dns_server_ip                = optional(string, "10.70.3.4")
  })
  default = { vnet_cidr = "10.70.0.0/16"
    host_subnet_cidr             = "10.70.0.0/24"
    container_subnet_cidr        = "10.70.1.0/24"
    private_endpoint_subnet_cidr = "10.70.2.0/26"
    test_vm_subnet_cidr          = "10.70.4.0/27"
    dns_subnet_cidr              = "10.70.3.0/27"
    dns_server_ip                = "10.70.3.4"
  }
}
variable "sql_database_network" {
  type = object({ vnet_address_space = list(string)
    private_endpoint_subnet_prefixes = list(string)
  })
  default = { vnet_address_space = ["10.80.0.0/16"]
    private_endpoint_subnet_prefixes = ["10.80.1.0/24"]
  }
}
variable "sql_database" {
  description = "Azure SQL Database options."
  type = object({
    # Peer the SQL VNet with the workspace VNet and link its private DNS zone so
    # classic compute and the test VM can reach the server privately.
    workspace_peering_enabled = optional(bool, false)
    # Make the deploying principal the server's Microsoft Entra administrator.
    # SQL authentication stays enabled.
    entra_admin_enabled = optional(bool, true)
  })
  default = {}

  validation {
    condition = (
      !var.sql_database.workspace_peering_enabled ||
      (var.features.workspace && var.features.sql_database)
    )
    error_message = "sql_database.workspace_peering_enabled requires features.workspace and features.sql_database."
  }

  validation {
    condition = !var.sql_database.workspace_peering_enabled || alltrue([
      for cidr in var.sql_database_network.vnet_address_space : !(
        cidrhost("${cidrhost(cidr, 0)}/${split("/", var.workspace_network.vnet_cidr)[1]}", 0) == cidrhost(var.workspace_network.vnet_cidr, 0) ||
        cidrhost("${cidrhost(var.workspace_network.vnet_cidr, 0)}/${split("/", cidr)[1]}", 0) == cidrhost(cidr, 0)
      )
    ])
    error_message = "sql_database_network.vnet_address_space must not overlap workspace_network.vnet_cidr when workspace peering is enabled."
  }
}
variable "key_vault" {
  description = "Azure Key Vault that stores the generated SQL passwords, optionally exposed to the workspace as a Key Vault-backed secret scope."
  type = object({
    enabled                         = optional(bool, true)
    databricks_secret_scope_enabled = optional(bool, true)
    secret_scope_name               = optional(string, "sts-infra")
  })
  default = {}

  validation {
    condition     = can(regex("^[A-Za-z0-9_.@-]{1,128}$", var.key_vault.secret_scope_name))
    error_message = "key_vault.secret_scope_name may contain only letters, digits, underscores, periods, hyphens, and @, up to 128 characters."
  }
}
variable "connectivity" {
  description = "Serverless connectivity for Azure data sources. private_link creates an NCC private endpoint rule; approve it with ./infra endpoints azure."
  type = object({
    sql_database = optional(object({
      serverless = optional(string, "none")
    }), {})
  })
  default = {}

  validation {
    condition     = contains(["none", "private_link"], var.connectivity.sql_database.serverless)
    error_message = "Serverless connectivity modes must be none or private_link."
  }

  validation {
    condition = (
      var.connectivity.sql_database.serverless == "none" ||
      (var.features.workspace && var.features.sql_database && var.databricks_account_id != null)
    )
    error_message = "connectivity.sql_database.serverless = \"private_link\" requires features.workspace, features.sql_database, and databricks_account_id."
  }
}
variable "existing_network_connectivity_config_id" {
  description = "Optional existing Databricks NCC ID to reuse for serverless private endpoint rules."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.existing_network_connectivity_config_id == null || trimspace(var.existing_network_connectivity_config_id) != ""
    error_message = "existing_network_connectivity_config_id must be null or a non-empty NCC ID."
  }
}
variable "sql_vm_network" {
  type = object({ vnet_address_space = list(string)
    vm_subnet_prefixes                   = list(string)
    private_link_service_subnet_prefixes = list(string)
    vm_private_ip                        = string
  })
  default = { vnet_address_space = ["10.90.0.0/16"]
    vm_subnet_prefixes                   = ["10.90.1.0/24"]
    private_link_service_subnet_prefixes = ["10.90.2.0/24"]
    vm_private_ip                        = "10.90.1.4"
  }
}
variable "tags" {
  type = map(string)
  default = { ManagedBy = "terraform"
    Environment = "demo"
  }
}
variable "allow_destructive_demo_cleanup" {
  description = "Disposable labs only: let destroy delete resource groups that still contain resources Terraform does not manage, such as ones injected by Azure Policy."
  type        = bool
  default     = false
}
variable "target" {
  description = "Named account target from the local targets file (./infra targets). ./infra resolves it to the subscription, tenant, Databricks account, and default location; Terraform only records it."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.target == null || can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", var.target))
    error_message = "target must be null or a target name such as \"field-sandbox\"."
  }
}
variable "endpoint_approval" {
  description = "How ./infra handles serverless NCC private endpoint connections after apply: auto approves the connections this deployment requested; manual leaves them for ./infra endpoints azure approve."
  type        = string
  default     = "auto"

  validation {
    condition     = contains(["auto", "manual"], var.endpoint_approval)
    error_message = "endpoint_approval must be auto or manual."
  }
}
variable "lab_check" {
  description = "Sample data and connectivity checks run by ./infra verify."
  type = object({
    enabled           = optional(bool, true)
    classic_node_type = optional(string)
  })
  default = {}
}
