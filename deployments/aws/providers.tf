provider "aws" {
  region              = var.region
  profile             = var.aws_profile
  allowed_account_ids = var.aws_account_id == null ? null : [var.aws_account_id]
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

# Workspace-level resources authenticate directly to the workspace host. The
# unified provider (account host + workspace_id) was tested with an account
# OAuth U2M profile: it created storage credentials but external locations
# failed with "Authentication failed", so a workspace login is still required.
provider "databricks" {
  alias   = "workspace"
  host    = try(module.workspace[0].workspace_url, "https://workspace-not-created.invalid")
  profile = try(coalesce(var.databricks_workspace_profile, var.databricks_profile), null)
}
