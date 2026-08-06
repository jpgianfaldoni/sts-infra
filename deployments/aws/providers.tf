provider "aws" {
  region  = var.region
  profile = var.aws_profile
  default_tags {
    tags = var.tags
  }
}

provider "databricks" {
  alias      = "mws"
  host       = "https://accounts.cloud.databricks.com"
  account_id = var.databricks_account_id
  profile    = var.databricks_profile
}

provider "databricks" {
  alias   = "workspace"
  host    = try(module.workspace[0].workspace_url, "https://workspace-not-created.invalid")
  profile = coalesce(var.databricks_workspace_profile, var.databricks_profile)
}
