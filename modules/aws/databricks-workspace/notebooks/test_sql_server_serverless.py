# Databricks notebook source
# MAGIC %md
# MAGIC # SQL Server connectivity test from serverless compute
# MAGIC
# MAGIC This notebook validates the NCC/PrivateLink path and reads the seeded
# MAGIC `dbo.customers` and `dbo.orders` tables. Credentials are retrieved from
# MAGIC a Databricks-backed secret scope and are never stored in the notebook.

# COMMAND ----------

import socket

dbutils.widgets.text(
    "host",
    "your-sql-server.example.internal",
)
dbutils.widgets.text("port", "1433")
dbutils.widgets.text("database", "demo")
dbutils.widgets.text("secret_scope", "sql-server")

host = dbutils.widgets.get("host")
port = int(dbutils.widgets.get("port"))
database = dbutils.widgets.get("database")
secret_scope = dbutils.widgets.get("secret_scope")

username = dbutils.secrets.get(scope=secret_scope, key="master-username")
password = dbutils.secrets.get(scope=secret_scope, key="master-password")

print(f"Testing SQL Server at {host}:{port}, database={database}")

# COMMAND ----------

with socket.create_connection((host, port), timeout=15):
    print("TCP connectivity succeeded through the serverless NCC private endpoint")

# COMMAND ----------

jdbc_url = (
    f"jdbc:sqlserver://{host}:{port};"
    f"databaseName={database};"
    "encrypt=true;"
    # This demo follows the existing database seeder. For production, install
    # and validate the RDS CA certificate instead of trusting the server cert.
    "trustServerCertificate=true;"
    "loginTimeout=30;"
)

jdbc_options = {
    "user": username,
    "password": password,
    "driver": "com.microsoft.sqlserver.jdbc.SQLServerDriver",
}


def read_table(table_name: str):
    return (
        spark.read.format("jdbc")
        .option("url", jdbc_url)
        .option("dbtable", table_name)
        .options(**jdbc_options)
        .load()
    )


customers = read_table("dbo.customers")
orders = read_table("dbo.orders")

customer_count = customers.count()
order_count = orders.count()

print(f"Read customers={customer_count}, orders={order_count}")
customers.orderBy("customer_id").show(truncate=False)
orders.orderBy("order_id").show(truncate=False)

assert customer_count >= 3, f"Expected at least 3 customers, found {customer_count}"
assert order_count >= 5, f"Expected at least 5 orders, found {order_count}"

print("SQL Server serverless read test passed")
