variable "region" {
  type    = string
  default = "us-west-2"
}
variable "aws_profile" {
  description = "Optional local AWS CLI profile. Prefer AWS_PROFILE for operators or the standard AWS credential chain for automation."
  type        = string
  default     = null
  nullable    = true
}
variable "databricks_profile" {
  description = "Optional local Databricks account profile. Prefer DATABRICKS_ACCOUNT_PROFILE for operators or unified-auth environment variables for automation."
  type        = string
  default     = null
  nullable    = true
}
variable "databricks_workspace_profile" {
  description = "Optional local workspace profile when the account profile cannot authenticate to workspace APIs. Prefer DATABRICKS_WORKSPACE_PROFILE."
  type        = string
  default     = null
  nullable    = true
}
variable "aws_account_id" {
  description = "Optional expected AWS account ID. When set, the AWS provider refuses to operate in any other account."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.aws_account_id == null || can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be null or a 12-digit AWS account ID."
  }
}
variable "databricks_account_id" {
  type = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.databricks_account_id))
    error_message = "databricks_account_id must be a Databricks account UUID."
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
variable "deployment_id" {
  description = "Deployment ID supplied by ./infra (the tfvars filename or INFRA_DEPLOYMENT_ID). Resource names derive from it when name_prefix is not set."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.deployment_id == null || can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", var.deployment_id))
    error_message = "deployment_id must match [A-Za-z0-9][A-Za-z0-9._-]{0,127}."
  }
}
variable "name_prefix" {
  description = "Prefix for resource names. When null, it is derived from deployment_id (lowercased, at most 24 characters), or \"demo\" when neither is set."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.name_prefix == null || trimspace(coalesce(var.name_prefix, " ")) != ""
    error_message = "name_prefix must be null or a non-empty string."
  }
}
variable "workspace_name" {
  description = "Databricks workspace name. When null, it is \"<name prefix>-classic\"."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.workspace_name == null || trimspace(coalesce(var.workspace_name, " ")) != ""
    error_message = "workspace_name must be null or a non-empty string."
  }
}
variable "availability_zones" {
  description = "Optional pair of availability zones. When omitted, the first two available zones in var.region are selected."
  type        = list(string)
  default     = null
  nullable    = true

  validation {
    condition = var.availability_zones == null || (
      length(var.availability_zones) == 2 &&
      var.availability_zones[0] != var.availability_zones[1] &&
      alltrue([for zone in var.availability_zones : startswith(zone, var.region)])
    )
    error_message = "availability_zones must contain two distinct zones in the selected AWS region."
  }
}
variable "workspace_network" {
  type = object({
    vpc_cidr                    = string
    private_subnet_cidrs        = list(string)
    public_subnet_cidr          = string
    tgw_attachment_subnet_cidrs = optional(list(string), ["10.40.33.0/28", "10.40.33.16/28"])
  })
  default = { vpc_cidr = "10.40.0.0/18"
    private_subnet_cidrs = ["10.40.0.0/20", "10.40.16.0/20"]
    public_subnet_cidr   = "10.40.32.0/24"
  }

  validation {
    condition = length(var.workspace_network.tgw_attachment_subnet_cidrs) == 2 && alltrue([
      for cidr in var.workspace_network.tgw_attachment_subnet_cidrs :
      can(cidrnetmask(cidr)) && !strcontains(cidr, ":")
    ])
    error_message = "workspace_network must provide exactly two valid IPv4 Transit Gateway attachment subnet CIDRs."
  }
}
variable "workspace_backend_private_link" {
  description = "Optional back-end PrivateLink for classic compute-to-control-plane traffic. Public workspace access remains enabled by default."
  type = object({
    enabled               = optional(bool, false)
    endpoint_subnet_cidrs = optional(list(string), [])
    public_access_enabled = optional(bool, true)
  })
  default = {}

  validation {
    condition = !var.workspace_backend_private_link.enabled || (
      length(var.workspace_backend_private_link.endpoint_subnet_cidrs) == 2 &&
      alltrue([
        for cidr in var.workspace_backend_private_link.endpoint_subnet_cidrs :
        can(cidrnetmask(cidr)) && !strcontains(cidr, ":")
      ])
    )
    error_message = "workspace_backend_private_link requires exactly two valid IPv4 endpoint subnet CIDRs when enabled."
  }
}
variable "unity_catalog" {
  description = "Unity Catalog metastore selection and optional initial catalog resources. metastore_mode: create (a dedicated metastore), existing (existing_metastore_name), or auto (reuse the account's metastore in the region, otherwise create one)."
  type = object({
    metastore_mode          = optional(string, "create")
    existing_metastore_name = optional(string)
    create_initial_catalog  = optional(bool, true)
  })
  default = {}

  validation {
    condition     = contains(["create", "existing", "auto"], var.unity_catalog.metastore_mode)
    error_message = "unity_catalog.metastore_mode must be create, existing, or auto."
  }

  validation {
    condition     = var.unity_catalog.existing_metastore_name == null || trimspace(coalesce(var.unity_catalog.existing_metastore_name, " ")) != ""
    error_message = "unity_catalog.existing_metastore_name must be null or a non-empty metastore name."
  }

  validation {
    condition     = var.unity_catalog.metastore_mode != "existing" || var.unity_catalog.existing_metastore_name != null
    error_message = "unity_catalog.metastore_mode = \"existing\" requires unity_catalog.existing_metastore_name."
  }

  validation {
    condition     = var.unity_catalog.metastore_mode != "auto" || var.unity_catalog.existing_metastore_name == null
    error_message = "unity_catalog.existing_metastore_name selects a specific metastore; do not combine it with metastore_mode = \"auto\"."
  }
}
variable "glue_federation" {
  description = "AWS Glue federation configuration, with optional Databricks Unity Catalog resources."
  type = object({
    databricks_connectivity_enabled  = optional(bool, false)
    databricks_unity_catalog_iam_arn = optional(string, "arn:aws:iam::414351767826:role/unity-catalog-prod-UCMasterRole-14S5ZJVKOTYTL")
    service_credential_external_id   = optional(string, "0000")
    storage_credential_external_id   = optional(string, "0000")
  })
  default = {}

  validation {
    condition = (
      trimspace(var.glue_federation.service_credential_external_id) != "" &&
      trimspace(var.glue_federation.storage_credential_external_id) != "" &&
      can(regex("^arn:[^:]+:iam::[0-9]{12}:role/.+$", var.glue_federation.databricks_unity_catalog_iam_arn))
    )
    error_message = "Glue federation credential external IDs must not be empty, and the Unity Catalog principal must be a valid IAM role ARN."
  }

  validation {
    condition = !var.glue_federation.databricks_connectivity_enabled || (
      var.features.glue_federation &&
      var.features.workspace &&
      var.features.unity_catalog
    )
    error_message = "Glue federation Databricks connectivity requires the glue_federation, workspace, and unity_catalog features."
  }
}
variable "rds_postgres" {
  description = "RDS PostgreSQL engine and Lakeflow Connect source configuration."
  type = object({
    engine_version           = optional(string)
    lakeflow_connect_enabled = optional(bool, false)
  })
  default = {}

  validation {
    condition = !var.rds_postgres.lakeflow_connect_enabled || (
      try(tonumber(split(".", var.rds_postgres.engine_version)[0]), 0) >= 13
    )
    error_message = "rds_postgres.lakeflow_connect_enabled requires an explicit PostgreSQL engine_version of 13 or newer."
  }
}
variable "features" {
  type = object({
    workspace         = optional(bool, true)
    unity_catalog     = optional(bool, true)
    glue_federation   = optional(bool, false)
    rds_postgres      = optional(bool, false)
    rds_sql_server    = optional(bool, false)
    aurora_postgres   = optional(bool, false)
    aurora_proxy      = optional(bool, false)
    rabbitmq          = optional(bool, false)
    kafka             = optional(bool, false)
    simulated_on_prem = optional(bool, false)
  })
  default = {
  }
  validation {
    condition     = (!var.features.unity_catalog || var.features.workspace) && (!var.features.aurora_proxy || var.features.aurora_postgres)
    error_message = "unity_catalog requires workspace; aurora_proxy requires aurora_postgres."
  }
}
variable "connectivity" {
  description = "Choose classic and serverless connectivity independently for each service."
  type = object({
    rds_postgres = optional(object({
      classic    = optional(string, "none")
      serverless = optional(string, "none")
    }), {})
    rds_sql_server = optional(object({
      classic    = optional(string, "none")
      serverless = optional(string, "none")
    }), {})
    aurora_postgres = optional(object({
      classic    = optional(string, "none")
      serverless = optional(string, "none")
    }), {})
    rabbitmq = optional(object({
      classic    = optional(string, "none")
      serverless = optional(string, "none")
    }), {})
    kafka = optional(object({
      classic    = optional(string, "none")
      serverless = optional(string, "none")
    }), {})
    simulated_on_prem = optional(object({
      classic    = optional(string, "none")
      serverless = optional(string, "none")
    }), {})
  })
  default = {
  }
  validation {
    condition = alltrue([for value in [
      var.connectivity.rds_postgres.classic,
      var.connectivity.rds_sql_server.classic,
      var.connectivity.aurora_postgres.classic,
      var.connectivity.rabbitmq.classic,
      var.connectivity.kafka.classic
    ] : contains(["none", "peering", "private_link"], value)])
    error_message = "Classic connectivity modes must be none, peering, or private_link."
  }
  validation {
    condition = alltrue([for value in [
      var.connectivity.rds_postgres.serverless,
      var.connectivity.rds_sql_server.serverless,
      var.connectivity.aurora_postgres.serverless,
      var.connectivity.rabbitmq.serverless,
      var.connectivity.kafka.serverless
    ] : contains(["none", "private_link"], value)])
    error_message = "Serverless connectivity modes must be none or private_link."
  }
  validation {
    condition     = contains(["none", "transit_gateway"], var.connectivity.simulated_on_prem.classic)
    error_message = "Simulated on-premises classic connectivity must be none or transit_gateway."
  }
  validation {
    condition     = contains(["none", "private_link"], var.connectivity.simulated_on_prem.serverless)
    error_message = "Simulated on-premises serverless connectivity must be none or private_link."
  }
  validation {
    condition = var.features.workspace || alltrue([for value in [
      var.connectivity.rds_postgres.classic,
      var.connectivity.rds_postgres.serverless,
      var.connectivity.rds_sql_server.classic,
      var.connectivity.rds_sql_server.serverless,
      var.connectivity.aurora_postgres.classic,
      var.connectivity.aurora_postgres.serverless,
      var.connectivity.rabbitmq.classic,
      var.connectivity.rabbitmq.serverless,
      var.connectivity.kafka.classic,
      var.connectivity.kafka.serverless,
      var.connectivity.simulated_on_prem.classic,
      var.connectivity.simulated_on_prem.serverless
    ] : value == "none"])
    error_message = "Databricks connectivity requires the workspace feature."
  }
  validation {
    condition = alltrue([
      var.features.rds_postgres || (var.connectivity.rds_postgres.classic == "none" && var.connectivity.rds_postgres.serverless == "none"),
      var.features.rds_sql_server || (var.connectivity.rds_sql_server.classic == "none" && var.connectivity.rds_sql_server.serverless == "none"),
      var.features.aurora_postgres || (var.connectivity.aurora_postgres.classic == "none" && var.connectivity.aurora_postgres.serverless == "none"),
      var.features.rabbitmq || (var.connectivity.rabbitmq.classic == "none" && var.connectivity.rabbitmq.serverless == "none"),
      var.features.kafka || (var.connectivity.kafka.classic == "none" && var.connectivity.kafka.serverless == "none"),
      var.features.simulated_on_prem || (var.connectivity.simulated_on_prem.classic == "none" && var.connectivity.simulated_on_prem.serverless == "none")
    ])
    error_message = "Connectivity can only be enabled for a service whose feature is enabled."
  }
}
variable "simulated_on_prem" {
  description = "Configuration for the optional private VPC that simulates an on-premises network."
  type = object({
    vpc_cidr                    = optional(string, "10.60.0.0/16")
    workload_subnet_cidr        = optional(string, "10.60.0.0/24")
    tgw_attachment_subnet_cidrs = optional(list(string), ["10.60.1.0/28", "10.60.1.16/28"])
    instance_type               = optional(string, "t3.micro")
    service_port                = optional(number, 8080)
  })
  default = {}

  validation {
    condition = (
      can(cidrnetmask(var.simulated_on_prem.vpc_cidr)) &&
      can(cidrnetmask(var.simulated_on_prem.workload_subnet_cidr)) &&
      !strcontains(var.simulated_on_prem.vpc_cidr, ":") &&
      !strcontains(var.simulated_on_prem.workload_subnet_cidr, ":") &&
      length(var.simulated_on_prem.tgw_attachment_subnet_cidrs) == 2 &&
      alltrue([
        for cidr in var.simulated_on_prem.tgw_attachment_subnet_cidrs :
        can(cidrnetmask(cidr)) && !strcontains(cidr, ":")
      ])
    )
    error_message = "Simulated on-premises networking requires valid IPv4 VPC/workload CIDRs and exactly two attachment subnet CIDRs."
  }

  validation {
    condition     = var.simulated_on_prem.service_port >= 1 && var.simulated_on_prem.service_port <= 65535
    error_message = "The simulated on-premises service port must be between 1 and 65535."
  }
}
variable "database_networks" {
  type = object({ rds_postgres = string
    rds_sql_server  = string
    aurora_postgres = string
    rabbitmq        = string
    kafka           = optional(string, "10.48.0.0/16")
  })
  default = { rds_postgres = "10.45.0.0/16"
    rds_sql_server  = "10.43.0.0/16"
    aurora_postgres = "10.46.0.0/16"
    rabbitmq        = "10.47.0.0/16"
    kafka           = "10.48.0.0/16"
  }
}

variable "kafka" {
  description = "Configuration for the disposable single-broker Kafka lab."
  type = object({
    instance_type             = optional(string, "t3.small")
    image                     = optional(string, "apache/kafka:3.9.1")
    topic_name                = optional(string, "demo-events")
    producer_interval_seconds = optional(number, 1)
    ephemeral_credentials     = optional(bool, false)
  })
  default = {}

  validation {
    condition     = var.kafka.producer_interval_seconds >= 1 && var.kafka.producer_interval_seconds <= 3600
    error_message = "kafka.producer_interval_seconds must be between 1 and 3600."
  }
}
variable "rabbitmq" {
  description = "Configuration for the self-managed RabbitMQ lab broker."
  type = object({
    ephemeral_credentials = optional(bool, false)
  })
  default = {}
}
variable "initial_catalog_name" {
  type    = string
  default = "main"
}
variable "allow_destructive_demo_cleanup" {
  type    = bool
  default = false
}
variable "tags" {
  type = map(string)
  default = { ManagedBy = "terraform"
    Environment = "demo"
  }
}
