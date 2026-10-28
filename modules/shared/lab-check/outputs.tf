output "job_id" {
  value = databricks_job.this.id
}

output "job_url" {
  value = databricks_job.this.url
}

output "managed_secret_scope" {
  description = "Databricks-backed scope that ./infra verify fills with the source credentials, or null."
  value       = try(databricks_secret_scope.this[0].name, null)
}

output "notebook_path" {
  value = databricks_notebook.lab_check.path
}

output "checks" {
  value = {
    for key, check in var.checks : key => {
      source    = check.source
      compute   = check.path
      mode      = check.mode
      engine    = check.engine
      host      = check.host
      port      = check.port
      seeded    = check.seed_file != null
      run_after = check.run_after
    }
  }
}
