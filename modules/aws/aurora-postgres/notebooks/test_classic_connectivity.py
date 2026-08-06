# Databricks notebook source
# MAGIC %md
# MAGIC # Test classic-compute connectivity to Aurora PostgreSQL
# MAGIC
# MAGIC Attach this notebook to a classic cluster in the `demo-classic`
# MAGIC workspace. It verifies the VPC-peering path to the Aurora read-only
# MAGIC endpoint and confirms that PostgreSQL routed the connection to a reader.

# COMMAND ----------

import socket

dbutils.widgets.text(
    "host",
    "aurora-reader.example.internal",
)
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

resolved_ips = sorted(
    {
        result[4][0]
        for result in socket.getaddrinfo(
            host,
            port,
            family=socket.AF_INET,
            type=socket.SOCK_STREAM,
        )
    }
)
print(f"Aurora reader endpoint resolved to private IPs: {resolved_ips}")

with socket.create_connection((host, port), timeout=15):
    print("TCP connectivity through VPC peering succeeded")

# COMMAND ----------

jdbc_url = f"jdbc:postgresql://{host}:{port}/{database}?sslmode=require"
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
    spark.read.format("jdbc")
    .option("url", jdbc_url)
    .option("dbtable", query)
    .option("user", username)
    .option("password", password)
    .option("driver", "org.postgresql.Driver")
    .load()
)

row = result.first()
assert row.database_name == database
assert row.is_read_replica is True, (
    "Expected the Aurora read-only endpoint to connect to a reader instance"
)

display(result)
print("Classic-compute Aurora reader connectivity test passed")
