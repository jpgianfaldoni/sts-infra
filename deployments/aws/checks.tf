# Warnings only: these combinations are valid Terraform but usually fail when
# ./infra runs from an operator machine outside the workspace network.
check "workspace_api_reachable_from_operator" {
  assert {
    condition = !(
      var.features.workspace &&
      var.workspace_backend_private_link.enabled &&
      !var.workspace_backend_private_link.public_access_enabled &&
      (
        (var.features.unity_catalog && var.unity_catalog.create_initial_catalog) ||
        var.glue_federation.databricks_connectivity_enabled
      )
    )
    error_message = "Workspace public access is disabled while workspace-scoped Databricks resources (initial Unity Catalog catalog or Glue federation connectivity) are enabled. Terraform and ./infra call workspace APIs from the operator machine: run from inside the workspace network or keep workspace_backend_private_link.public_access_enabled = true."
  }
}
