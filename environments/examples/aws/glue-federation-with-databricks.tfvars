databricks_account_id = "00000000-0000-0000-0000-000000000000"
name_prefix           = "acme-glue-test"
workspace_name        = "acme-glue-test-workspace"

features = {
  workspace       = true
  unity_catalog   = true
  glue_federation = true
}

# This mode creates the AWS resources and the complete Unity Catalog path:
# service credential, storage credential, external location, Glue connection,
# and foreign catalog. The credential external IDs and IAM trust are wired
# automatically; the manual external-ID fields are ignored.
glue_federation = {
  databricks_connectivity_enabled = true
}

allow_destructive_demo_cleanup = true

tags = {
  ManagedBy   = "terraform"
  Environment = "demo"
  Purpose     = "glue-federation"
}
