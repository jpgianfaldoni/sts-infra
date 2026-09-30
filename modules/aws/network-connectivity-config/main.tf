# Kept apart from the endpoint rules and the workspace binding so the workspace
# can depend on it: Databricks refuses to delete an NCC while a workspace is
# attached, so the workspace must be destroyed first.
resource "databricks_mws_network_connectivity_config" "this" {
  provider = databricks.mws
  name     = var.name
  region   = var.region
}
