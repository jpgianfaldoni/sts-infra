# Databricks notebook source
# MAGIC %md
# MAGIC # PostgreSQL connectivity test from serverless compute
# MAGIC
# MAGIC This notebook validates the NCC/PrivateLink path, writes a small test
# MAGIC table, and reads it back. Credentials come from a Databricks secret
# MAGIC scope and are never stored in the notebook.

# COMMAND ----------

import socket

dbutils.widgets.text("host", "your-postgres.example.internal")
dbutils.widgets.text("port", "5432")
dbutils.widgets.text("database", "demo")
dbutils.widgets.text("secret_scope", "postgres")

host = dbutils.widgets.get("host")
port = int(dbutils.widgets.get("port"))
database = dbutils.widgets.get("database")
secret_scope = dbutils.widgets.get("secret_scope")

username = dbutils.secrets.get(scope=secret_scope, key="master-username")
password = dbutils.secrets.get(scope=secret_scope, key="master-password")

print(f"Testing PostgreSQL at {host}:{port}, database={database}")

# COMMAND ----------

with socket.create_connection((host, port), timeout=15):
    print("TCP connectivity succeeded through the serverless NCC private endpoint")

# COMMAND ----------

postgres_options = {
    "host": host,
    "port": str(port),
    "database": database,
    "user": username,
    "password": password,
}

test_rows = [(1, "serverless PrivateLink to PostgreSQL works")]
test_df = spark.createDataFrame(test_rows, ["id", "message"])

(
    test_df.write.format("postgresql")
    .option("dbtable", "public.databricks_connectivity_test")
    .options(**postgres_options)
    .mode("overwrite")
    .save()
)

result = (
    spark.read.format("postgresql")
    .option("dbtable", "public.databricks_connectivity_test")
    .options(**postgres_options)
    .load()
)

rows = result.collect()
assert [(row.id, row.message) for row in rows] == test_rows
result.show(truncate=False)
print("PostgreSQL serverless read/write test passed")
