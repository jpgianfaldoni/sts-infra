# Databricks notebook source
# MAGIC %md
# MAGIC # Aurora PostgreSQL reader connectivity test from serverless compute
# MAGIC
# MAGIC Validates the NCC/PrivateLink path to the Aurora read-only endpoint and
# MAGIC confirms the connection is served by a reader instance.

# COMMAND ----------

import socket

dbutils.widgets.text("host", "your-aurora-reader.example.internal")
dbutils.widgets.text("port", "5432")
dbutils.widgets.text("database", "demo")
dbutils.widgets.text("secret_scope", "aurora")

host = dbutils.widgets.get("host")
port = int(dbutils.widgets.get("port"))
database = dbutils.widgets.get("database")
secret_scope = dbutils.widgets.get("secret_scope")

username = dbutils.secrets.get(scope=secret_scope, key="master-username")
password = dbutils.secrets.get(scope=secret_scope, key="master-password")

print(f"Testing Aurora reader at {host}:{port}, database={database}")

# COMMAND ----------

with socket.create_connection((host, port), timeout=15):
    print("TCP connectivity succeeded through the serverless NCC private endpoint")

# COMMAND ----------

query = """
(
  SELECT
    current_database() AS database_name,
    current_user AS connected_user,
    inet_server_addr()::text AS server_ip,
    pg_is_in_recovery() AS is_read_replica
) AS connection_test
"""

result = (
    spark.read.format("postgresql")
    .option("host", host)
    .option("port", str(port))
    .option("database", database)
    .option("user", username)
    .option("password", password)
    .option("dbtable", query)
    .load()
)

row = result.first()
assert row.database_name == database
assert row.is_read_replica is True, (
    "The Aurora read-only endpoint routed to a writer instance"
)

result.show(truncate=False)
print("Aurora PostgreSQL serverless reader test passed")
