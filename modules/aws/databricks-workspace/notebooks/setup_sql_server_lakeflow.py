# Databricks notebook source
# MAGIC %md
# MAGIC # Prepare AWS RDS SQL Server for Lakeflow Connect
# MAGIC
# MAGIC Installs the official Databricks Lakeflow SQL Server utility objects,
# MAGIC creates a dedicated ingestion login, enables CDC on the demo tables,
# MAGIC grants the documented RDS permissions, and verifies the result.

# COMMAND ----------

# MAGIC %pip install pymssql==2.3.8

# COMMAND ----------

import hashlib
import json
import re
import urllib.request
from pathlib import Path

import pymssql


UTILITY_SCRIPT_URL = (
    "https://docs.databricks.com/aws/en/assets/files/"
    "utility_script-9a7925923528101cbe1cba8b91d9997a.sql"
)
UTILITY_SCRIPT_SHA256 = (
    "56a3294264d153a3c52feb64f0b99d88f850c7f4212fa69e01a2a1fd7ebce6d3"
)
CDC_TABLES = "dbo.customers,dbo.orders"

dbutils.widgets.text("host", "your-sql-server.example.internal")
dbutils.widgets.text("port", "1433")
dbutils.widgets.text("database", "demo")
dbutils.widgets.text("secret_scope", "sql-server")
dbutils.widgets.text("ingestion_username", "databricks_ingestion")
dbutils.widgets.text(
    "seed_file_path",
    "/Workspace/Shared/aws_sql_server_seed.sql",
)

host = dbutils.widgets.get("host")
port = int(dbutils.widgets.get("port"))
database = dbutils.widgets.get("database")
secret_scope = dbutils.widgets.get("secret_scope")
ingestion_username = dbutils.widgets.get("ingestion_username")
seed_file_path = Path(dbutils.widgets.get("seed_file_path"))

identifier_pattern = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,127}$")
if not identifier_pattern.fullmatch(database):
    raise ValueError(f"Invalid database name: {database}")
if not identifier_pattern.fullmatch(ingestion_username):
    raise ValueError(f"Invalid ingestion username: {ingestion_username}")

master_username = dbutils.secrets.get(scope=secret_scope, key="master-username")
master_password = dbutils.secrets.get(scope=secret_scope, key="master-password")
ingestion_password = dbutils.secrets.get(
    scope=secret_scope,
    key="lakeflow-ingestion-password",
)


def connect(username: str, password: str, database_name: str = database):
    return pymssql.connect(
        server=host,
        port=port,
        user=username,
        password=password,
        database=database_name,
        login_timeout=30,
        timeout=0,
        autocommit=True,
    )


def execute_batches(connection, script: str) -> None:
    batches = re.split(r"(?im)^[\t ]*GO[\t ]*(?:--.*)?$", script)
    with connection.cursor() as cursor:
        for batch in batches:
            if batch.strip():
                cursor.execute(batch)


def sql_string(value: str) -> str:
    return "N'" + value.replace("'", "''") + "'"


print(f"Preparing SQL Server source at {host}:{port}, database={database}")

# COMMAND ----------

with urllib.request.urlopen(UTILITY_SCRIPT_URL, timeout=60) as response:
    utility_script_bytes = response.read()

actual_checksum = hashlib.sha256(utility_script_bytes).hexdigest()
if actual_checksum != UTILITY_SCRIPT_SHA256:
    raise RuntimeError(
        "The downloaded Lakeflow utility script checksum did not match the "
        "reviewed version. Review the new script before running it."
    )

utility_script = utility_script_bytes.decode("utf-8-sig")

# COMMAND ----------

seed_script = seed_file_path.read_text(encoding="utf-8")
with connect(master_username, master_password, "master") as connection:
    execute_batches(connection, seed_script)
print("Demo database and source tables seeded")

# COMMAND ----------

with connect(master_username, master_password) as connection:
    with connection.cursor() as cursor:
        cursor.execute(
            "SELECT OBJECT_ID(N'dbo.lakeflowUtilityVersion_1_5', N'FN')"
        )
        utility_function_id = cursor.fetchone()[0]
        if utility_function_id is None:
            installed_version = None
        else:
            cursor.execute("SELECT dbo.lakeflowUtilityVersion_1_5()")
            installed_version = cursor.fetchone()[0]

    if installed_version != "1.5":
        print("Installing reviewed Lakeflow utility objects version 1.5")
        execute_batches(connection, utility_script)
    else:
        print("Lakeflow utility objects version 1.5 already installed")

    login_literal = sql_string(ingestion_username)
    password_literal = sql_string(ingestion_password)
    with connection.cursor() as cursor:
        cursor.execute(
            f"""
            IF SUSER_ID({login_literal}) IS NULL
                CREATE LOGIN [{ingestion_username}]
                    WITH PASSWORD = {password_literal},
                         CHECK_POLICY = ON,
                         CHECK_EXPIRATION = OFF;
            ELSE
                ALTER LOGIN [{ingestion_username}]
                    WITH PASSWORD = {password_literal};

            IF USER_ID({login_literal}) IS NULL
                CREATE USER [{ingestion_username}]
                    FOR LOGIN [{ingestion_username}];
            """
        )

        cursor.execute(
            "EXEC dbo.lakeflowSetupChangeDataCapture "
            "@Tables = %s, @User = %s",
            (CDC_TABLES, ingestion_username),
        )
        cursor.execute(
            "EXEC dbo.lakeflowFixPermissions @User = %s, @Tables = %s",
            (ingestion_username, CDC_TABLES),
        )

        cursor.execute(
            "SELECT dbo.lakeflowUtilityVersion_1_5(), "
            "dbo.lakeflowDetectPlatform(), "
            "(SELECT is_cdc_enabled FROM sys.databases WHERE name = DB_NAME())"
        )
        utility_version, platform, database_cdc_enabled = cursor.fetchone()

        cursor.execute(
            "SELECT COUNT(*) FROM sys.tables t "
            "JOIN sys.schemas s ON s.schema_id = t.schema_id "
            "WHERE s.name = N'dbo' "
            "AND t.name IN (N'customers', N'orders') "
            "AND t.is_tracked_by_cdc = 1"
        )
        tracked_table_count = cursor.fetchone()[0]

        cursor.execute(
            "SELECT COUNT(*) FROM cdc.change_tables "
            "WHERE capture_instance LIKE N'lakeflow[_]dbo[_]%'")
        lakeflow_capture_instance_count = cursor.fetchone()[0]

if utility_version != "1.5":
    raise AssertionError(f"Unexpected utility version: {utility_version}")
if platform != "AMAZON_RDS":
    raise AssertionError(f"Unexpected platform: {platform}")
if database_cdc_enabled != 1:
    raise AssertionError("CDC is not enabled on the demo database")
if tracked_table_count != 2:
    raise AssertionError(
        f"Expected CDC on two demo tables, found {tracked_table_count}"
    )
if lakeflow_capture_instance_count < 2:
    raise AssertionError(
        "Expected Lakeflow-managed CDC capture instances for both demo tables"
    )

# COMMAND ----------

with connect(ingestion_username, ingestion_password) as connection:
    with connection.cursor() as cursor:
        cursor.execute(
            "SELECT "
            "(SELECT COUNT(*) FROM dbo.customers), "
            "(SELECT COUNT(*) FROM dbo.orders), "
            "HAS_PERMS_BY_NAME(N'dbo', N'SCHEMA', N'SELECT'), "
            "HAS_PERMS_BY_NAME(DB_NAME(), N'DATABASE', N'VIEW DATABASE STATE')"
        )
        customer_count, order_count, can_select_dbo, can_view_database_state = (
            cursor.fetchone()
        )

if customer_count < 3 or order_count < 5:
    raise AssertionError(
        f"Unexpected source row counts: customers={customer_count}, orders={order_count}"
    )
if can_select_dbo != 1:
    raise AssertionError("The ingestion user cannot SELECT from the dbo schema")
if can_view_database_state != 1:
    raise AssertionError("The ingestion user lacks VIEW DATABASE STATE")

print("Lakeflow Connect SQL Server source setup verified successfully")
print(f"Utility version: {utility_version}")
print(f"Platform: {platform}")
print(f"Database CDC enabled: {bool(database_cdc_enabled)}")
print(f"CDC-enabled demo tables: {tracked_table_count}")
print(f"Lakeflow capture instances: {lakeflow_capture_instance_count}")
print(f"Source rows: customers={customer_count}, orders={order_count}")

dbutils.notebook.exit(
    json.dumps(
        {
            "utility_version": utility_version,
            "platform": platform,
            "database_cdc_enabled": bool(database_cdc_enabled),
            "cdc_enabled_demo_tables": tracked_table_count,
            "lakeflow_capture_instances": lakeflow_capture_instance_count,
            "customers": customer_count,
            "orders": order_count,
            "ingestion_user_verified": True,
        }
    )
)
