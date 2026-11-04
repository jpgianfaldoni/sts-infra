mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-west-2a", "us-west-2b"]
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/mock-policy"
    }
  }
  mock_data "aws_ami" {
    defaults = {
      id = "ami-0123456789abcdef0"
    }
  }
  mock_data "aws_network_interface" {
    defaults = {
      private_ip = "10.45.1.10"
    }
  }
}
mock_provider "databricks" {
  alias = "mws"
  mock_resource "databricks_mws_workspaces" {
    override_during = plan
    defaults = {
      workspace_url = "https://example.cloud.databricks.com"
    }
  }
  mock_data "databricks_aws_assume_role_policy" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_data "databricks_aws_crossaccount_policy" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_data "databricks_aws_bucket_policy" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_data "databricks_aws_unity_catalog_assume_role_policy" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_data "databricks_aws_unity_catalog_policy" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_data "databricks_metastore" {
    defaults = {
      id           = "11111111-2222-3333-4444-555555555555"
      metastore_id = "11111111-2222-3333-4444-555555555555"
      region       = "us-west-2"
    }
  }
  mock_data "databricks_metastores" {
    defaults = {
      ids = {}
    }
  }
}
mock_provider "databricks" {
  alias = "workspace"
}
# The real random provider runs locally without cloud access. It is used instead
# of a mock because mock providers do not support ephemeral resources, which the
# brokers use for credentials that must never enter state.
provider "random" {}
mock_provider "time" {}
mock_provider "archive" {}

run "derive_availability_zones_from_region" {
  command = plan

  override_data {
    target = data.aws_availability_zones.available
    values = {
      names = ["ca-central-1a", "ca-central-1b", "ca-central-1d"]
    }
  }

  variables {
    region                = "ca-central-1"
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = false
      unity_catalog = false
    }
  }

  assert {
    condition     = output.availability_zones == tolist(["ca-central-1a", "ca-central-1b"])
    error_message = "Availability zones must be derived from the selected AWS region."
  }
}

run "reject_availability_zones_from_another_region" {
  command = plan

  variables {
    region                = "ca-central-1"
    availability_zones    = ["us-west-2a", "us-west-2b"]
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = false
      unity_catalog = false
    }
  }

  expect_failures = [var.availability_zones]
}

run "all_features_disabled" {
  command = plan
  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace       = false
      unity_catalog   = false
      rds_postgres    = false
      rds_sql_server  = false
      aurora_postgres = false
      aurora_proxy    = false
      rabbitmq        = false
      kafka           = false
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
  assert {
    condition     = length(output.pending_endpoint_acceptances) == 0
    error_message = "No endpoint acceptances can be pending without PrivateLink connectivity."
  }
}

run "glue_federation_aws_resources_only" {
  command = apply

  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace       = false
      unity_catalog   = false
      glue_federation = true
    }
  }

  assert {
    condition     = output.workspace_url == null
    error_message = "The AWS-only Glue federation component must not create a Databricks workspace."
  }

  assert {
    condition     = output.glue_federation.glue_database_name == "demo_glue_federation"
    error_message = "The Glue database name must be derived from the deployment prefix."
  }

  assert {
    condition = (
      !output.glue_federation.service_trust_finalized &&
      !output.glue_federation.storage_trust_finalized &&
      !output.glue_federation.databricks_connectivity_enabled &&
      output.glue_federation.service_credential_name == null &&
      output.glue_federation.storage_credential_name == null &&
      output.glue_federation.external_location_name == null &&
      output.glue_federation.connection_name == null &&
      output.glue_federation.foreign_catalog_name == null
    )
    error_message = "AWS-only Glue federation must use placeholder trust and omit all Databricks resources."
  }
}

run "glue_federation_with_databricks_connectivity" {
  command = plan

  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace       = true
      unity_catalog   = true
      glue_federation = true
    }
    glue_federation = {
      databricks_connectivity_enabled = true
    }
  }

  assert {
    condition = (
      output.glue_federation.databricks_connectivity_enabled &&
      output.glue_federation.service_credential_name == "demo_glue_service_credential" &&
      output.glue_federation.storage_credential_name == "demo_glue_storage_credential" &&
      output.glue_federation.external_location_name == "demo_glue_external_location" &&
      output.glue_federation.connection_name == "demo_glue_connection" &&
      output.glue_federation.foreign_catalog_name == "demo_glue_catalog" &&
      output.glue_federation.service_trust_finalized &&
      output.glue_federation.storage_trust_finalized
    )
    error_message = "Databricks-enabled Glue federation must compose every Unity Catalog resource with neutral prefix-derived names."
  }
}

run "reject_glue_databricks_connectivity_without_workspace_and_unity_catalog" {
  command = plan

  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace       = false
      unity_catalog   = false
      glue_federation = true
    }
    glue_federation = {
      databricks_connectivity_enabled = true
    }
  }

  expect_failures = [var.glue_federation]
}

run "reject_orphan_unity_catalog" {
  command = plan
  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = false
      unity_catalog = true
    }
  }
  expect_failures = [var.features]
}

run "workspace_and_postgres_without_connectivity" {
  command = plan
  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = true
      unity_catalog = false
      rds_postgres  = true
    }
    connectivity = {
      rds_postgres = {
        classic    = "none"
        serverless = "none"
      }
    }
  }
  assert {
    condition     = output.connectivity.rds_postgres.classic.mode == "none" && output.connectivity.rds_postgres.serverless.mode == "none"
    error_message = "The service must remain disconnected when both modes are none."
  }
  assert {
    condition     = length(output.ncc_rules) == 0
    error_message = "NCC must not be created without serverless PrivateLink."
  }
  assert {
    condition     = length(output.pending_endpoint_acceptances) == 0
    error_message = "No endpoint acceptances can be pending without PrivateLink connectivity."
  }
  assert {
    condition     = output.connectivity.rds_postgres.classic.endpoint_service_id == null && output.connectivity.rds_postgres.serverless.endpoint_service_id == null
    error_message = "Endpoint service IDs must be null when PrivateLink is not selected."
  }
  assert {
    condition     = output.workspace_url == "https://example.cloud.databricks.com"
    error_message = "The workspace URL must contain exactly one scheme."
  }
}

run "workspace_uses_existing_metastore_without_initial_catalog" {
  command = plan

  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = true
      unity_catalog = true
    }
    unity_catalog = {
      existing_metastore_name = "jpg-classic-uc-metastore"
      create_initial_catalog  = false
    }
  }

  assert {
    condition     = output.metastore_id == "11111111-2222-3333-4444-555555555555"
    error_message = "The workspace must use the existing metastore selected by name."
  }

  assert {
    condition     = output.catalog_name == null
    error_message = "Assignment-only mode must not create an initial catalog."
  }
}

run "workspace_with_backend_private_link" {
  command = plan

  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = true
      unity_catalog = false
    }
    workspace_backend_private_link = {
      enabled               = true
      endpoint_subnet_cidrs = ["10.40.34.0/27", "10.40.34.32/27"]
      public_access_enabled = true
    }
  }

  assert {
    condition     = output.workspace_backend_private_link.enabled && output.workspace_backend_private_link.public_access_enabled
    error_message = "The workspace must enable back-end PrivateLink while retaining public front-end access."
  }
}

run "warn_when_workspace_api_unreachable_from_operator" {
  command = plan

  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = true
      unity_catalog = true
    }
    workspace_backend_private_link = {
      enabled               = true
      endpoint_subnet_cidrs = ["10.40.34.0/27", "10.40.34.32/27"]
      public_access_enabled = false
    }
  }

  expect_failures = [check.workspace_api_reachable_from_operator]
}

run "reject_backend_private_link_without_two_endpoint_subnets" {
  command = plan

  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = true
      unity_catalog = false
    }
    workspace_backend_private_link = {
      enabled               = true
      endpoint_subnet_cidrs = ["10.40.34.0/27"]
    }
  }

  expect_failures = [var.workspace_backend_private_link]
}

run "postgres_without_workspace_or_connectivity" {
  command = plan
  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = false
      unity_catalog = false
      rds_postgres  = true
    }
    connectivity = {
      rds_postgres = {
        classic    = "none"
        serverless = "none"
      }
    }
  }
  assert {
    condition     = output.workspace_url == null
    error_message = "A standalone service deployment must not create a workspace."
  }
}

run "classic_peering_and_serverless_private_link" {
  command = plan
  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = true
      unity_catalog = false
      rds_postgres  = true
    }
    connectivity = {
      rds_postgres = {
        classic    = "peering"
        serverless = "private_link"
      }
    }
  }
  assert {
    condition     = output.connectivity.rds_postgres.classic.mode == "peering"
    error_message = "Classic compute must use peering."
  }
  assert {
    condition     = output.connectivity.rds_postgres.serverless.mode == "private_link"
    error_message = "Serverless compute must use PrivateLink."
  }
}

run "classic_and_serverless_private_link" {
  command = plan
  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = true
      unity_catalog = false
      rds_postgres  = true
    }
    connectivity = {
      rds_postgres = {
        classic    = "private_link"
        serverless = "private_link"
      }
    }
  }
  assert {
    condition     = output.connectivity.rds_postgres.classic.mode == "private_link" && output.connectivity.rds_postgres.serverless.mode == "private_link"
    error_message = "Both compute types must use PrivateLink."
  }
}

run "all_services_for_classic_and_serverless_private_link" {
  command = plan
  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace       = true
      unity_catalog   = false
      rds_postgres    = true
      rds_sql_server  = true
      aurora_postgres = true
      aurora_proxy    = false
      rabbitmq        = true
      kafka           = true
    }
    connectivity = {
      rds_postgres = {
        classic    = "private_link"
        serverless = "private_link"
      }
      rds_sql_server = {
        classic    = "private_link"
        serverless = "private_link"
      }
      aurora_postgres = {
        classic    = "private_link"
        serverless = "private_link"
      }
      rabbitmq = {
        classic    = "private_link"
        serverless = "private_link"
      }
      kafka = {
        classic    = "private_link"
        serverless = "private_link"
      }
    }
  }
  assert {
    condition = alltrue([
      output.connectivity.rds_postgres.serverless.mode == "private_link",
      output.connectivity.rds_sql_server.serverless.mode == "private_link",
      output.connectivity.aurora_postgres.serverless.mode == "private_link",
      output.connectivity.rabbitmq.serverless.mode == "private_link",
      output.connectivity.kafka.serverless.mode == "private_link"
    ])
    error_message = "All five services must enable serverless PrivateLink."
  }
}

run "kafka_classic_peering_and_serverless_private_link" {
  command = plan

  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = true
      unity_catalog = false
      kafka         = true
    }
    connectivity = {
      kafka = {
        classic    = "peering"
        serverless = "private_link"
      }
    }
  }

  assert {
    condition     = output.connectivity.kafka.classic.mode == "peering" && output.connectivity.kafka.classic.port == 9092
    error_message = "Classic Kafka must use its direct peering listener."
  }

  assert {
    condition     = output.connectivity.kafka.serverless.mode == "private_link" && output.connectivity.kafka.serverless.port == 9094
    error_message = "Serverless Kafka must use its PrivateLink listener."
  }

}

run "reject_kafka_connectivity_when_disabled" {
  command = plan

  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = true
      unity_catalog = false
      kafka         = false
    }
    connectivity = {
      kafka = {
        classic = "peering"
      }
    }
  }

  expect_failures = [var.connectivity]
}

run "reject_serverless_peering" {
  command = plan
  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = true
      unity_catalog = false
      rds_postgres  = true
    }
    connectivity = {
      rds_postgres = {
        serverless = "peering"
      }
    }
  }
  expect_failures = [var.connectivity]
}

run "reject_connectivity_for_disabled_service" {
  command = plan
  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = true
      unity_catalog = false
      rds_postgres  = false
    }
    connectivity = {
      rds_postgres = {
        classic = "peering"
      }
    }
  }
  expect_failures = [var.connectivity]
}

run "standalone_simulated_on_prem" {
  command = apply

  override_resource {
    target = module.simulated_on_prem[0].aws_instance.host
    values = {
      id = "i-0123456789abcdef0"
    }
  }

  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace         = false
      unity_catalog     = false
      simulated_on_prem = true
    }
  }
  assert {
    condition     = output.simulated_on_prem.ssm_command == "aws ssm start-session --target i-0123456789abcdef0 --region us-west-2"
    error_message = "The SSM command must include the region and omit --profile when no profile is selected."
  }
  assert {
    condition     = output.workspace_url == null
    error_message = "A standalone simulated network must not create a Databricks workspace."
  }
  assert {
    condition     = output.connectivity.simulated_on_prem.classic.mode == "none" && output.connectivity.simulated_on_prem.classic.transit_gateway_id == null
    error_message = "A standalone simulated network must not create Transit Gateway connectivity."
  }
}

run "workspace_and_simulated_on_prem_disconnected" {
  command = plan
  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace         = true
      unity_catalog     = false
      simulated_on_prem = true
    }
    connectivity = {
      simulated_on_prem = {
        classic = "none"
      }
    }
  }
  assert {
    condition     = output.connectivity.simulated_on_prem.classic.mode == "none" && output.connectivity.simulated_on_prem.classic.transit_gateway_id == null
    error_message = "Disconnected mode must not create Transit Gateway connectivity."
  }
}

run "workspace_to_simulated_on_prem_transit_gateway" {
  command = plan
  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace         = true
      unity_catalog     = false
      simulated_on_prem = true
    }
    connectivity = {
      simulated_on_prem = {
        classic = "transit_gateway"
      }
    }
  }
  assert {
    condition     = output.connectivity.simulated_on_prem.classic.mode == "transit_gateway"
    error_message = "Classic compute must use Transit Gateway for the connected simulated network."
  }
}

run "workspace_to_simulated_on_prem_serverless_private_link" {
  command = plan
  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace         = true
      unity_catalog     = false
      simulated_on_prem = true
    }
    connectivity = {
      simulated_on_prem = {
        serverless = "private_link"
      }
    }
  }
  assert {
    condition     = output.connectivity.simulated_on_prem.serverless.mode == "private_link"
    error_message = "Serverless compute must reach the simulated network through PrivateLink."
  }
}

run "workspace_to_simulated_on_prem_classic_and_serverless" {
  command = plan
  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace         = true
      unity_catalog     = false
      simulated_on_prem = true
    }
    connectivity = {
      simulated_on_prem = {
        classic    = "transit_gateway"
        serverless = "private_link"
      }
    }
  }
  assert {
    condition     = output.connectivity.simulated_on_prem.classic.mode == "transit_gateway" && output.connectivity.simulated_on_prem.serverless.mode == "private_link"
    error_message = "The simulated network must support classic Transit Gateway and serverless PrivateLink simultaneously."
  }
}

run "reject_simulated_on_prem_serverless_peering" {
  command = plan
  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace         = true
      unity_catalog     = false
      simulated_on_prem = true
    }
    connectivity = {
      simulated_on_prem = {
        serverless = "peering"
      }
    }
  }
  expect_failures = [var.connectivity]
}

run "reject_simulated_on_prem_connectivity_without_workspace" {
  command = plan
  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace         = false
      unity_catalog     = false
      simulated_on_prem = true
    }
    connectivity = {
      simulated_on_prem = {
        classic = "transit_gateway"
      }
    }
  }
  expect_failures = [var.connectivity]
}

run "reject_simulated_on_prem_connectivity_when_disabled" {
  command = plan
  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace         = true
      unity_catalog     = false
      simulated_on_prem = false
    }
    connectivity = {
      simulated_on_prem = {
        classic = "transit_gateway"
      }
    }
  }
  expect_failures = [var.connectivity]
}

run "reject_overlapping_workspace_and_simulated_on_prem_cidrs" {
  command = plan
  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace         = true
      unity_catalog     = false
      simulated_on_prem = true
    }
    connectivity = {
      simulated_on_prem = {
        classic = "transit_gateway"
      }
    }
    simulated_on_prem = {
      vpc_cidr                    = "10.40.0.0/16"
      workload_subnet_cidr        = "10.40.64.0/24"
      tgw_attachment_subnet_cidrs = ["10.40.65.0/28", "10.40.65.16/28"]
    }
  }
  expect_failures = [terraform_data.simulated_on_prem_network_validation[0]]
}

run "reject_invalid_workspace_tgw_attachment_subnet_count" {
  command = plan
  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace         = true
      unity_catalog     = false
      simulated_on_prem = true
    }
    connectivity = {
      simulated_on_prem = {
        classic = "transit_gateway"
      }
    }
    workspace_network = {
      vpc_cidr                    = "10.40.0.0/18"
      private_subnet_cidrs        = ["10.40.0.0/20", "10.40.16.0/20"]
      public_subnet_cidr          = "10.40.32.0/24"
      tgw_attachment_subnet_cidrs = ["10.40.33.0/28"]
    }
  }
  expect_failures = [var.workspace_network]
}

run "ssm_command_uses_selected_profile" {
  command = apply

  override_resource {
    target = module.simulated_on_prem[0].aws_instance.host
    values = {
      id = "i-0123456789abcdef0"
    }
  }

  variables {
    aws_profile           = "sts-lab"
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace         = false
      unity_catalog     = false
      simulated_on_prem = true
    }
  }

  assert {
    condition     = output.simulated_on_prem.ssm_command == "aws ssm start-session --target i-0123456789abcdef0 --region us-west-2 --profile sts-lab"
    error_message = "The SSM command must use the AWS profile selected by ./infra."
  }
}

run "accept_expected_aws_account_id" {
  command = plan

  variables {
    aws_account_id        = "123456789012"
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = false
      unity_catalog = false
    }
  }

  assert {
    condition     = output.workspace_url == null
    error_message = "A valid expected AWS account ID must be accepted."
  }
}

run "reject_invalid_aws_account_id" {
  command = plan

  variables {
    aws_account_id        = "1234"
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = false
      unity_catalog = false
    }
  }

  expect_failures = [var.aws_account_id]
}

run "reject_invalid_databricks_account_id" {
  command = plan

  variables {
    databricks_account_id = "not-a-uuid"
    features = {
      workspace     = false
      unity_catalog = false
    }
  }

  expect_failures = [var.databricks_account_id]
}

run "metastore_create_is_the_default" {
  command = plan

  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = true
      unity_catalog = true
    }
    unity_catalog = {
      create_initial_catalog = false
    }
  }

  assert {
    condition     = output.metastore_created == true
    error_message = "Without metastore_mode, the deployment must keep creating a dedicated metastore."
  }
}

run "metastore_auto_reuses_regional_metastore" {
  command = plan

  override_data {
    target = module.unity_catalog[0].data.databricks_metastores.all
    values = {
      ids = { "shared-us-west-2" = "11111111-2222-3333-4444-555555555555" }
    }
  }

  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = true
      unity_catalog = true
    }
    unity_catalog = {
      metastore_mode         = "auto"
      create_initial_catalog = false
    }
  }

  assert {
    condition     = output.metastore_created == false && output.metastore_id == "11111111-2222-3333-4444-555555555555"
    error_message = "Auto mode must assign the metastore that already exists in the workspace region."
  }
}

run "reject_ambiguous_auto_metastore" {
  command = plan

  # Shared accounts can hold several metastores per region; auto mode must not
  # pick one of them arbitrarily.
  override_data {
    target = module.unity_catalog[0].data.databricks_metastores.all
    values = {
      ids = {
        "team-a-us-west-2" = "11111111-2222-3333-4444-555555555555"
        "team-b-us-west-2" = "22222222-3333-4444-5555-666666666666"
      }
    }
  }

  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = true
      unity_catalog = true
    }
    unity_catalog = {
      metastore_mode         = "auto"
      create_initial_catalog = false
    }
  }

  expect_failures = [output.metastore_id]
}

run "metastore_auto_ignores_other_regions" {
  command = plan

  override_data {
    target = module.unity_catalog[0].data.databricks_metastores.all
    values = {
      ids = { "shared-eu-west-1" = "99999999-2222-3333-4444-555555555555" }
    }
  }

  override_data {
    target = module.unity_catalog[0].data.databricks_metastore.candidate
    values = {
      id           = "99999999-2222-3333-4444-555555555555"
      metastore_id = "99999999-2222-3333-4444-555555555555"
      region       = "eu-west-1"
    }
  }

  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = true
      unity_catalog = true
    }
    unity_catalog = {
      metastore_mode         = "auto"
      create_initial_catalog = false
    }
  }

  assert {
    condition     = output.metastore_created == true
    error_message = "Auto mode must create a metastore when none exists in the workspace region."
  }
}

run "metastore_auto_keeps_managing_its_own_metastore" {
  command = plan

  override_data {
    target = module.unity_catalog[0].data.databricks_metastores.all
    values = {
      ids = { "demo-metastore" = "11111111-2222-3333-4444-555555555555" }
    }
  }

  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = true
      unity_catalog = true
    }
    unity_catalog = {
      metastore_mode         = "auto"
      create_initial_catalog = false
    }
  }

  assert {
    condition     = output.metastore_created == true
    error_message = "A metastore created by auto mode must stay managed on later plans instead of being treated as pre-existing."
  }
}

run "reject_auto_metastore_with_existing_name" {
  command = plan

  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = true
      unity_catalog = true
    }
    unity_catalog = {
      metastore_mode          = "auto"
      existing_metastore_name = "shared"
    }
  }

  expect_failures = [var.unity_catalog]
}

run "reject_existing_metastore_mode_without_name" {
  command = plan

  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = true
      unity_catalog = true
    }
    unity_catalog = {
      metastore_mode = "existing"
    }
  }

  expect_failures = [var.unity_catalog]
}

run "names_derive_from_deployment_id" {
  command = plan

  variables {
    deployment_id         = "My_Lab.2026"
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = false
      unity_catalog = false
    }
  }

  assert {
    condition     = output.resource_name_prefix == "my-lab-2026"
    error_message = "The name prefix must be the sanitized deployment ID."
  }
}

run "derived_names_start_with_a_letter_and_are_truncated" {
  command = plan

  variables {
    deployment_id         = "2026-a-very-long-deployment-identifier-for-testing"
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = false
      unity_catalog = false
    }
  }

  assert {
    condition     = output.resource_name_prefix == "d-2026-a-very-long-deploym"
    error_message = "Derived prefixes must start with a letter and stay within the length budget."
  }
}

run "explicit_name_prefix_wins_over_deployment_id" {
  command = plan

  variables {
    deployment_id         = "my-lab"
    name_prefix           = "acme-demo"
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = false
      unity_catalog = false
    }
  }

  assert {
    condition     = output.resource_name_prefix == "acme-demo"
    error_message = "An explicit name_prefix must be used unchanged."
  }
}

run "names_fall_back_to_demo" {
  command = plan

  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = false
      unity_catalog = false
    }
  }

  assert {
    condition     = output.resource_name_prefix == "demo"
    error_message = "Without a deployment ID or name_prefix, names must keep the demo default."
  }
}

run "brokers_with_ephemeral_credentials" {
  command = plan

  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = true
      unity_catalog = false
      kafka         = true
      rabbitmq      = true
    }
    connectivity = {
      kafka = {
        classic    = "private_link"
        serverless = "private_link"
      }
      rabbitmq = {
        classic    = "private_link"
        serverless = "none"
      }
    }
    kafka = {
      ephemeral_credentials = true
    }
    rabbitmq = {
      ephemeral_credentials = true
    }
  }

  assert {
    condition     = output.connectivity.kafka.classic.mode == "private_link" && output.connectivity.rabbitmq.classic.mode == "private_link"
    error_message = "Brokers with ephemeral credentials must plan with classic PrivateLink."
  }
}

run "lab_check_seeds_postgres_over_classic_peering" {
  command = plan
  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace    = true
      rds_postgres = true
    }
    connectivity = {
      rds_postgres = {
        classic    = "peering"
        serverless = "none"
      }
    }
  }
  assert {
    condition     = keys(output.lab_check.checks) == ["rds_postgres_classic"]
    error_message = "Only the configured classic path must be checked."
  }
  assert {
    condition     = output.lab_check.checks.rds_postgres_classic.engine == "postgresql" && output.lab_check.checks.rds_postgres_classic.seeded
    error_message = "The PostgreSQL check must load the sample data."
  }
  assert {
    condition     = length(output.lab_check.credentials) == 1 && output.lab_check.credentials[0].username_key == "rds_postgres-username"
    error_message = "./infra verify must copy the PostgreSQL credentials into the scope."
  }
  assert {
    condition     = output.deployment_stage == "complete"
    error_message = "A plan without the stage override is the complete stage."
  }
}

run "foundation_stage_defers_workspace_resources" {
  command = plan
  variables {
    databricks_account_id       = "00000000-0000-0000-0000-000000000000"
    workspace_resources_enabled = false
    features = {
      workspace     = true
      unity_catalog = true
      rds_postgres  = true
    }
    connectivity = {
      rds_postgres = {
        classic    = "peering"
        serverless = "none"
      }
    }
  }
  assert {
    condition     = output.lab_check == null && output.metastore_created == null
    error_message = "The foundation stage must not create workspace-level resources."
  }
  assert {
    condition     = output.deployment_stage == "foundation"
    error_message = "The foundation stage must be reported."
  }
  assert {
    condition     = output.connectivity.rds_postgres.classic.mode == "peering"
    error_message = "The foundation stage still creates the network path."
  }
}

run "lab_check_serverless_runs_after_classic" {
  command = plan
  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace      = true
      unity_catalog  = false
      rds_sql_server = true
    }
    connectivity = {
      rds_sql_server = {
        classic    = "private_link"
        serverless = "private_link"
      }
    }
  }
  assert {
    condition     = keys(output.lab_check.checks) == ["rds_sql_server_classic", "rds_sql_server_serverless"]
    error_message = "Both configured paths must be checked."
  }
  assert {
    condition = (
      output.lab_check.checks.rds_sql_server_serverless.run_after == "rds_sql_server_classic" &&
      output.lab_check.checks.rds_sql_server_classic.run_after == null
    )
    error_message = "The serverless check must run after the classic check so seeding never races."
  }
}

run "lab_check_tests_brokers_over_tcp" {
  command = plan
  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = true
      unity_catalog = false
      kafka         = true
    }
    connectivity = {
      kafka = {
        classic    = "peering"
        serverless = "none"
      }
    }
  }
  assert {
    condition     = output.lab_check.checks.kafka_classic.engine == "tcp" && !output.lab_check.checks.kafka_classic.seeded
    error_message = "Brokers are checked for TCP reachability only."
  }
  assert {
    condition     = length(output.lab_check.credentials) == 0
    error_message = "TCP checks need no credentials."
  }
}

run "lab_check_can_be_disabled" {
  command = plan
  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    lab_check = {
      enabled = false
    }
    features = {
      workspace     = true
      unity_catalog = false
      rds_postgres  = true
    }
    connectivity = {
      rds_postgres = {
        classic    = "peering"
        serverless = "none"
      }
    }
  }
  assert {
    condition     = output.lab_check == null
    error_message = "lab_check.enabled = false must not create the job."
  }
}

run "no_lab_check_without_a_path" {
  command = plan
  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = true
      unity_catalog = false
      rds_postgres  = true
    }
  }
  assert {
    condition     = output.lab_check == null
    error_message = "A disconnected source has nothing to check."
  }
}

run "reject_unknown_endpoint_approval" {
  command = plan
  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    endpoint_approval     = "sometimes"
  }
  expect_failures = [var.endpoint_approval]
}

run "foundation_without_workspace_resources_is_complete" {
  command = plan
  variables {
    databricks_account_id       = "00000000-0000-0000-0000-000000000000"
    workspace_resources_enabled = false
    features = {
      workspace     = true
      unity_catalog = false
    }
  }
  assert {
    condition     = output.deployment_stage == "complete" && !output.workspace_resources_requested
    error_message = "A workspace without workspace-level resources needs no second stage."
  }
}
