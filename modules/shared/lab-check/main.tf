locals {
  folder      = "/Shared/sts-infra/${var.name_prefix}"
  has_classic = anytrue([for check in values(var.checks) : check.path == "classic"])

  # One seed file per source, shared by every compute path that checks it.
  seed_files = {
    for source in distinct([for check in values(var.checks) : check.source if check.seed_file != null]) :
    source => one(distinct([for check in values(var.checks) : check.seed_file if check.source == source && check.seed_file != null]))
  }
}

resource "databricks_secret_scope" "this" {
  count = var.managed_secret_scope == null ? 0 : 1

  name = var.managed_secret_scope
}

resource "databricks_notebook" "lab_check" {
  path   = "${local.folder}/lab_check"
  source = "${path.module}/notebooks/lab_check.py"
}

resource "databricks_workspace_file" "seed" {
  for_each = local.seed_files

  path   = "${local.folder}/seed/${each.key}.sql"
  source = each.value
}

data "databricks_current_user" "me" {}

data "databricks_spark_version" "lts" {
  count = local.has_classic ? 1 : 0

  long_term_support = true
}

data "databricks_node_type" "smallest" {
  count = local.has_classic && var.classic_node_type == null ? 1 : 0

  local_disk = false
  min_cores  = 4
  category   = "General Purpose"
}

# Classic tasks share one single-node job cluster; serverless tasks omit
# compute and run on serverless jobs compute. When a source has both paths,
# the serverless task runs after the classic one so seeding never races.
resource "databricks_job" "this" {
  name                = "${var.name_prefix}-lab-check"
  description         = "Created by sts-infra. Loads the sample data and checks each configured network path; run it with ./infra verify."
  max_concurrent_runs = 1
  timeout_seconds     = 3600

  tags = {
    managed_by = "sts-infra"
  }

  dynamic "job_cluster" {
    for_each = local.has_classic ? [1] : []
    content {
      job_cluster_key = "classic"
      new_cluster {
        spark_version      = data.databricks_spark_version.lts[0].id
        node_type_id       = coalesce(var.classic_node_type, try(data.databricks_node_type.smallest[0].id, null))
        num_workers        = 0
        data_security_mode = "SINGLE_USER"
        single_user_name   = data.databricks_current_user.me.user_name
        spark_conf = {
          "spark.databricks.cluster.profile" = "singleNode"
          "spark.master"                     = "local[*]"
        }
        custom_tags = {
          ResourceClass = "SingleNode"
        }
      }
    }
  }

  dynamic "task" {
    for_each = var.checks
    content {
      task_key        = task.key
      job_cluster_key = task.value.path == "classic" ? "classic" : null
      run_if          = task.value.run_after == null ? null : "ALL_DONE"
      timeout_seconds = 1800

      dynamic "depends_on" {
        for_each = task.value.run_after == null ? [] : [task.value.run_after]
        content {
          task_key = depends_on.value
        }
      }

      notebook_task {
        notebook_path = databricks_notebook.lab_check.path
        source        = "WORKSPACE"
        base_parameters = {
          cloud   = var.cloud
          source  = task.value.source
          compute = task.value.path
          mode    = task.value.mode
          engine  = task.value.engine
          host    = task.value.host
          port    = tostring(task.value.port)
          # coalesce() rejects all-empty arguments, so try() supplies "".
          database      = try(coalesce(task.value.database), "")
          seed_database = try(coalesce(task.value.seed_database, task.value.database), "")
          seed_path     = try("/Workspace${databricks_workspace_file.seed[task.value.source].path}", "")
          secret_scope  = try(coalesce(task.value.secret_scope), "")
          username_key  = try(coalesce(task.value.username_key), "")
          password_key  = try(coalesce(task.value.password_key), "")
        }
      }
    }
  }

  depends_on = [databricks_secret_scope.this]
}
