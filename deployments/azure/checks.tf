# Warnings only: this combination is valid Terraform but usually fails when
# ./infra runs from an operator machine outside the workspace network.
check "workspace_api_reachable_from_operator" {
  assert {
    condition = !(
      var.features.workspace &&
      var.features.external_volume_storage &&
      !var.workspace_front_end_private_link.public_network_access_enabled
    )
    error_message = "Workspace public network access is disabled while external_volume_storage creates workspace-scoped Unity Catalog objects. Terraform calls workspace APIs from the operator machine: run from inside the workspace network (for example the test VM) or keep workspace_front_end_private_link.public_network_access_enabled = true."
  }
}

check "front_end_private_link_enabled_deprecated" {
  assert {
    condition     = var.workspace_front_end_private_link.enabled == null
    error_message = "workspace_front_end_private_link.enabled is deprecated; rename it to browser_authentication_enabled. Until then it still controls the browser SSO endpoint when browser_authentication_enabled is unset. The databricks_ui_api private endpoint is always created. The old name will be removed in the next release."
  }
}

check "browser_sso_without_public_access" {
  assert {
    condition = !(
      var.features.workspace &&
      !var.workspace_front_end_private_link.public_network_access_enabled &&
      !local.browser_authentication_enabled
    )
    error_message = "Public workspace access is disabled without a browser_authentication endpoint. Browser SSO then needs another workspace in this region that provides one; otherwise set workspace_front_end_private_link.browser_authentication_enabled = true."
  }
}
