# Databricks notebook source
# MAGIC %md
# MAGIC # Validate the Terraform-managed initial catalog
# MAGIC
# MAGIC This test creates a managed Delta table, writes and reads rows, and
# MAGIC verifies that Unity Catalog placed the table in the dedicated S3 bucket.

# COMMAND ----------

dbutils.widgets.text("catalog", "initial_catalog")
dbutils.widgets.text("expected_bucket", "s3://your-catalog-bucket/")

catalog = dbutils.widgets.get("catalog")
schema = "validation"
table = "terraform_catalog_test"
full_table_name = f"{catalog}.{schema}.{table}"
expected_bucket = dbutils.widgets.get("expected_bucket")

spark.sql(f"CREATE SCHEMA IF NOT EXISTS {catalog}.{schema}")
spark.sql(
    f"""
    CREATE OR REPLACE TABLE {full_table_name} (
      id INT,
      message STRING
    ) USING DELTA
    """
)
spark.sql(
    f"""
    INSERT INTO {full_table_name} VALUES
      (1, 'catalog storage works'),
      (2, 'managed by terraform')
    """
)

# COMMAND ----------

rows = spark.table(full_table_name).orderBy("id").collect()
assert [(row.id, row.message) for row in rows] == [
    (1, "catalog storage works"),
    (2, "managed by terraform"),
]

detail = spark.sql(f"DESCRIBE DETAIL {full_table_name}").first()
assert detail.location.startswith(expected_bucket), (
    f"Expected table storage under {expected_bucket}, found {detail.location}"
)

print(f"Validated {len(rows)} rows in {full_table_name}")
print(f"Managed table location: {detail.location}")
print("Initial catalog storage test passed")
