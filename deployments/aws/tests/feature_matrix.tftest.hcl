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
}
mock_provider "databricks" {
  alias = "workspace"
}
mock_provider "random" {}
mock_provider "time" {}
mock_provider "archive" {}

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
    }
  }
  assert {
    condition     = output.workspace_url == null
    error_message = "The workspace must not be composed when its feature is disabled."
  }
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
    condition     = output.workspace_url == "https://example.cloud.databricks.com"
    error_message = "The workspace URL must contain exactly one scheme."
  }
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
    }
  }
  assert {
    condition = alltrue([
      output.connectivity.rds_postgres.serverless.mode == "private_link",
      output.connectivity.rds_sql_server.serverless.mode == "private_link",
      output.connectivity.aurora_postgres.serverless.mode == "private_link",
      output.connectivity.rabbitmq.serverless.mode == "private_link"
    ])
    error_message = "All four services must enable serverless PrivateLink."
  }
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
  command = plan
  variables {
    databricks_account_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace         = false
      unity_catalog     = false
      simulated_on_prem = true
    }
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
