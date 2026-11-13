# Databricks notebook source
# MAGIC %md
# MAGIC # sts-infra lab check
# MAGIC
# MAGIC Created by Terraform and run by `./infra verify`. Each task checks one
# MAGIC compute path (classic or serverless) to one data source:
# MAGIC
# MAGIC 1. resolves the source host and opens a TCP connection over the private path;
# MAGIC 2. for databases, loads the sample data idempotently and counts the rows;
# MAGIC 3. when the source is configured for Lakeflow Connect, prepares it for
# MAGIC    change capture (CDC or change tracking on SQL Server, logical
# MAGIC    replication on PostgreSQL) and checks the ingestion user's access.
# MAGIC
# MAGIC Credentials come from a Databricks secret scope and are never printed.

# COMMAND ----------

import importlib
import importlib.metadata
import json
import re
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import traceback

PARAMETERS = (
    "cloud",
    "source",
    "compute",
    "mode",
    "engine",
    "host",
    "port",
    "database",
    "seed_database",
    "seed_path",
    "secret_scope",
    "username_key",
    "password_key",
    "cdc_method",
    "cdc_username_key",
    "cdc_password_key",
)
for name in PARAMETERS:
    dbutils.widgets.text(name, "")
params = {name: dbutils.widgets.get(name).strip() for name in PARAMETERS}

cloud = params["cloud"] or "<cloud>"
engine = params["engine"]
host = params["host"]
port = int(params["port"])
compute = params["compute"]
mode = params["mode"]

# Database drivers are installed from PyPI so the same code runs on classic
# and serverless compute. Each entry is the driver's complete dependency set,
# pinned and installed with --no-deps, so a new upstream release cannot change
# what a lab runs (scramp 1.5 removed an API pg8000 1.31 calls).
# tests/test_lab_check_drivers.py checks that each set is complete and works.
DRIVERS = {
    "postgresql": (
        ("pg8000==1.31.2", "scramp==1.4.18", "asn1crypto==1.5.1", "python-dateutil==2.9.0.post0", "six==1.17.0"),
        "pg8000.native",
    ),
    "sqlserver": (("pymssql==2.3.8",), "pymssql"),
    "mysql": (("PyMySQL==1.2.3",), "pymysql"),
    # python-oracledb thin mode needs no Oracle client libraries.
    "oracle": (
        ("oracledb==26.1.0", "cryptography==50.0.2", "cffi==2.1.1", "pycparser==3.12", "typing_extensions==4.16.0"),
        "oracledb",
    ),
}
TCP_TIMEOUT_SECONDS = 15
SAMPLE_TABLES = ("customers", "orders")
# Databricks' SQL Server utility objects script for Lakeflow Connect source setup.
LAKEFLOW_UTILITY_SCRIPT_URL = "https://learn.microsoft.com/en-us/azure/databricks/_extras/documents/utility_script.sql"
CDC_METHODS = ("sqlserver_cdc", "sqlserver_ct", "postgresql_logical", "mysql_binlog", "oracle_logminer")
# Oracle sample tables live in this schema; the seed creates it.
ORACLE_SCHEMA = "LAB"
ORACLE_SETUP_DOCS_URL = "https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/oracle-integrated-setup"
POSTGRES_PUBLICATION = "databricks_publication"
POSTGRES_SLOT = "databricks_slot"
IDENTIFIER = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,62}$")

# The step in progress, reported when an unexpected error interrupts it.
stage = "dns"
driver_dir = None

result = {
    "source": params["source"],
    "compute": compute,
    "mode": mode,
    "engine": engine,
    "host": host,
    "port": port,
}

print(f"Checking {compute} compute -> {params['source']} ({mode}) at {host}:{port}")

# COMMAND ----------


def path_hint():
    if compute == "serverless":
        return (
            "Serverless compute reaches this source through the NCC private endpoint. "
            f"Run ./infra endpoints {cloud} status: the connection must be approved and the rule "
            "ESTABLISHED, which can take about 10 minutes after approval."
        )
    hints = {
        "peering": f"Check the peering routes and that the source's security rules allow port {port} from the workspace network.",
        "private_link": f"Check the PrivateLink endpoint in the workspace network and that its security group allows port {port}.",
        "transit_gateway": f"Check the Transit Gateway attachments and routes, and that the target allows port {port} from the workspace network.",
    }
    return hints.get(mode, "Check the network path between the workspace and the source.")


class LabCheckFailed(RuntimeError):
    pass


def fail(stage, message, hint):
    result.update(status="failed", stage=stage, error=message, hint=hint)
    print(json.dumps(result, indent=2))
    raise LabCheckFailed(f"LAB CHECK FAILED at {stage}: {message} Hint: {hint}")


def enter(next_stage):
    global stage
    stage = next_stage


def driver_versions():
    if driver_dir is None:
        return {}
    return {dist.metadata["Name"]: dist.version for dist in importlib.metadata.distributions(path=[driver_dir])}


def fail_unexpected(error):
    """Report an error no check anticipated, with enough detail to act on."""
    traceback.print_exc()
    frames = traceback.extract_tb(error.__traceback__)
    last = frames[-1] if frames else None
    failed_stage = stage
    # An error raised inside the installed driver is a driver problem, even
    # when it happens while connecting.
    if last is not None and driver_dir is not None and last.filename.startswith(driver_dir):
        failed_stage = "driver"
    where = f" at {last.filename.split('/sts-lab-check-')[-1]}:{last.lineno} in {last.name}" if last else ""
    versions = ", ".join(f"{name}=={version}" for name, version in sorted(driver_versions().items())) or "none installed"
    result["driver_packages"] = driver_versions()
    hint = (
        f"Unexpected error during the {failed_stage} step{where}. Driver packages: {versions}. "
        "A driver error usually means an incompatible package version; the pinned sets are in DRIVERS in lab_check.py."
    )
    fail(failed_stage, f"{type(error).__name__}: {error}", hint)


def check_network():
    try:
        addresses = sorted({info[4][0] for info in socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)})
    except socket.gaierror as error:
        fail("dns", f"could not resolve {host} ({error}).", path_hint())
    result["resolved"] = addresses
    enter("tcp")
    started = time.monotonic()
    try:
        with socket.create_connection((host, port), timeout=TCP_TIMEOUT_SECONDS):
            pass
    except OSError as error:
        fail("tcp", f"could not open a TCP connection to {host}:{port} within {TCP_TIMEOUT_SECONDS}s ({error}).", path_hint())
    result["tcp_ms"] = round((time.monotonic() - started) * 1000)
    print(f"TCP connection succeeded in {result['tcp_ms']} ms; {host} resolved to {', '.join(addresses)}")


def load_driver():
    global driver_dir
    enter("driver")
    packages, module = DRIVERS[engine]
    # Install into a directory of this task's own: classic tasks share one
    # cluster and may run at the same time, and serverless site-packages may
    # not be writable. The pinned set is always installed, so a different
    # driver version on the runtime cannot change the result.
    target = tempfile.mkdtemp(prefix="sts-lab-check-")
    try:
        subprocess.run(
            [sys.executable, "-m", "pip", "install", "--quiet", "--disable-pip-version-check", "--no-deps", "--target", target, *packages],
            check=True,
            capture_output=True,
            text=True,
            timeout=300,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        detail = getattr(error, "stderr", "") or str(error)
        # Compute without PyPI access may still have the driver preinstalled.
        try:
            return importlib.import_module(module)
        except ImportError:
            pass
        fail(
            "driver",
            f"could not install {' '.join(packages)}: {detail.strip()[-400:]}",
            "The check installs its database driver from PyPI, so this compute needs outbound internet access.",
        )
    driver_dir = target
    sys.path.insert(0, target)
    importlib.invalidate_caches()
    driver = importlib.import_module(module)
    result["driver_packages"] = driver_versions()
    return driver


def credentials(username_key=None, password_key=None):
    enter("credentials")
    username_key = username_key or params["username_key"]
    password_key = password_key or params["password_key"]
    try:
        username = dbutils.secrets.get(scope=params["secret_scope"], key=username_key)
        password = dbutils.secrets.get(scope=params["secret_scope"], key=password_key)
    except Exception as error:  # noqa: BLE001 - surface any secret lookup failure
        fail(
            "credentials",
            f"could not read {username_key}/{password_key} from secret scope {params['secret_scope']} ({type(error).__name__}).",
            f"./infra verify {cloud} <tfvars> copies the credentials into the scope before it runs this job.",
        )
    return username, password


def cdc_credentials():
    username, password = credentials(params["cdc_username_key"], params["cdc_password_key"])
    if not IDENTIFIER.match(username):
        fail("cdc", f"the ingestion user name {username!r} is not a simple identifier.", "Use letters, digits, and underscores.")
    return username, password


def cdc_hint():
    return (
        "The Lakeflow Connect source setup runs after the sample data loads and is safe to rerun; "
        "rerun ./infra verify after fixing the cause."
    )


def download_utility_script():
    import urllib.request

    try:
        with urllib.request.urlopen(LAKEFLOW_UTILITY_SCRIPT_URL, timeout=60) as response:
            script = response.read().decode("utf-8-sig")
    except Exception as error:  # noqa: BLE001 - report any download failure
        fail(
            "cdc",
            f"could not download the Lakeflow Connect utility objects script ({error}).",
            "The setup downloads it from learn.microsoft.com, so this compute needs outbound internet access.",
        )
    match = re.search(r"Version\s+([0-9]+(?:\.[0-9]+)*)", script)
    if "lakeflowSetupChangeDataCapture" not in script or not match:
        fail("cdc", "the downloaded file is not the Lakeflow Connect utility objects script.", cdc_hint())
    return script, match.group(1)


def login_hint():
    return f"The credentials in secret scope {params['secret_scope']} may be stale; ./infra verify refreshes them on every run."


def split_postgresql(script):
    """Split a SQL script on semicolons outside quotes and -- comments."""
    statements, current, quote, i = [], [], None, 0
    while i < len(script):
        char = script[i]
        if quote:
            current.append(char)
            if char == quote:
                quote = None
        elif char in ("'", '"'):
            quote = char
            current.append(char)
        elif script.startswith("--", i):
            end = script.find("\n", i)
            i = len(script) if end < 0 else end
            continue
        elif char == ";":
            statements.append("".join(current).strip())
            current = []
        else:
            current.append(char)
        i += 1
    statements.append("".join(current).strip())
    return [statement for statement in statements if statement]


def split_sqlserver(script):
    return [batch for batch in re.split(r"(?im)^[\t ]*GO[\t ]*(?:--.*)?$", script) if batch.strip()]


def read_seed():
    if not params["seed_path"]:
        return None
    with open(params["seed_path"], encoding="utf-8") as handle:
        return handle.read()


def check_postgresql():
    pg = load_driver()
    username, password = credentials()
    # Lab databases use the cloud provider's CA, and PrivateLink hosts do not
    # match the certificate name, so encrypt without verifying the server.
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE

    def connect(database, user=None, secret=None):
        enter("login")
        login = user or username
        try:
            return pg.Connection(
                login, host=host, port=port, database=database, password=secret or password, ssl_context=context, timeout=60
            )
        except (pg.DatabaseError, pg.InterfaceError) as error:
            fail("login", f"PostgreSQL rejected the connection for {login} ({error}).", login_hint())

    seed = read_seed()
    if seed is not None:
        connection = connect(params["seed_database"] or params["database"])
        enter("seed")
        for statement in split_postgresql(seed):
            connection.run(statement)
        connection.close()
        result["seeded"] = True
        print("Sample data loaded.")

    connection = connect(params["database"])
    enter("query")
    if seed is None:
        connection.run("SELECT 1")
        result["seeded"] = False
    else:
        result["rows"] = {table: connection.run(f"SELECT count(*) FROM public.{table}")[0][0] for table in SAMPLE_TABLES}
    connection.close()
    if seed is not None and params["cdc_method"] == "postgresql_logical":
        setup_postgresql_logical(connect)


def check_sqlserver():
    mssql = load_driver()
    username, password = credentials()

    def connect(database, user=None, secret=None):
        enter("login")
        login, secret = user or username, secret or password
        users = [login]
        # Azure SQL Database also accepts the user@server form some drivers need.
        if host.endswith(".database.windows.net") and "@" not in login:
            users.append(f"{login}@{host.split('.')[0]}")
        error = None
        for user in users:
            try:
                return mssql.connect(
                    server=host,
                    port=port,
                    user=user,
                    password=secret,
                    database=database,
                    login_timeout=30,
                    timeout=120,
                    autocommit=True,
                )
            except mssql.Error as caught:
                error = caught
        fail("login", f"SQL Server rejected the connection for {login} ({error}).", login_hint())

    seed = read_seed()
    if seed is not None:
        connection = connect(params["seed_database"] or params["database"])
        enter("seed")
        with connection.cursor() as cursor:
            for batch in split_sqlserver(seed):
                cursor.execute(batch)
                while cursor.nextset():
                    pass
        connection.close()
        result["seeded"] = True
        print("Sample data loaded.")

    connection = connect(params["database"])
    enter("query")
    with connection.cursor() as cursor:
        if seed is None:
            cursor.execute("SELECT 1")
            cursor.fetchall()
            result["seeded"] = False
        else:
            rows = {}
            for table in SAMPLE_TABLES:
                cursor.execute(f"SELECT COUNT(*) FROM dbo.{table}")
                rows[table] = cursor.fetchone()[0]
            result["rows"] = rows
    connection.close()
    if seed is not None and params["cdc_method"] in ("sqlserver_cdc", "sqlserver_ct"):
        setup_sqlserver_change_capture(connect)



# Lakeflow Connect source setup. It follows "Prepare SQL Server for ingestion
# using the utility objects script" and the PostgreSQL source setup in the
# Lakeflow Connect documentation, and is idempotent so every verify reruns it.

SQLSERVER_MASTER_GRANTS = [
    f"SELECT ON OBJECT::sys.{name}"
    for name in (
        "databases", "schemas", "tables", "columns", "key_constraints", "foreign_keys", "check_constraints",
        "default_constraints", "change_tracking_tables", "change_tracking_databases", "objects", "views", "triggers",
    )
] + [f"EXECUTE ON OBJECT::sys.{name}" for name in ("sp_tables", "sp_columns_100", "sp_pkeys", "sp_statistics_100")]
SQLSERVER_DATABASE_GRANTS = [
    f"SELECT ON OBJECT::sys.{name}"
    for name in ("indexes", "index_columns", "columns", "tables", "fulltext_index_columns", "fulltext_indexes")
] + ["SELECT ON SCHEMA::dbo"]
SQLSERVER_SET_LOGIN = """
DECLARE @sql NVARCHAR(MAX);
IF SUSER_ID(%s) IS NULL
    SET @sql = N'CREATE LOGIN ' + QUOTENAME(%s) + N' WITH PASSWORD = ' + QUOTENAME(%s, '''') + N';';
ELSE
    SET @sql = N'ALTER LOGIN ' + QUOTENAME(%s) + N' WITH PASSWORD = ' + QUOTENAME(%s, '''') + N';';
EXEC (@sql);
"""


def sql_scalar(cursor, statement, parameters=None):
    cursor.execute(statement, parameters)
    row = cursor.fetchone()
    while cursor.nextset():
        pass
    return None if row is None else row[0]


def sql_run(cursor, statement, parameters=None):
    cursor.execute(statement, parameters)
    while cursor.nextset():
        pass


def setup_sqlserver_change_capture(connect):
    method = params["cdc_method"]
    database = params["database"]
    tables = ",".join(f"dbo.{table}" for table in SAMPLE_TABLES)
    user, secret = cdc_credentials()
    quoted = f"[{user}]"
    enter("cdc")
    try:
        master = connect("master")
        enter("cdc")
        with master.cursor() as cursor:
            # EngineEdition 5 is Azure SQL Database; rdsadmin exists only on RDS.
            if sql_scalar(cursor, "SELECT CAST(SERVERPROPERTY('EngineEdition') AS INT)") == 5:
                platform = "azure_sql_database"
            elif sql_scalar(cursor, "SELECT DB_ID(N'rdsadmin')") is not None:
                platform = "rds"
            else:
                platform = "sql_server"
            sql_run(cursor, SQLSERVER_SET_LOGIN, (user, user, secret, user, secret))
            if platform == "azure_sql_database":
                sql_run(cursor, f"IF USER_ID(%s) IS NULL CREATE USER {quoted} FOR LOGIN {quoted};", (user,))
                sql_run(cursor, f"ALTER SERVER ROLE ##MS_DatabaseConnector## ADD MEMBER {quoted};")
            elif platform == "sql_server":
                # RDS grants these through the public role and has no master users.
                sql_run(cursor, f"IF USER_ID(%s) IS NULL CREATE USER {quoted} FOR LOGIN {quoted};", (user,))
                sql_run(cursor, f"GRANT VIEW ANY DATABASE TO {quoted};")
                for grant in SQLSERVER_MASTER_GRANTS:
                    sql_run(cursor, f"GRANT {grant} TO {quoted};")
        master.close()

        connection = connect(database)
        enter("cdc")
        with connection.cursor() as cursor:
            sql_run(cursor, f"IF USER_ID(%s) IS NULL CREATE USER {quoted} FOR LOGIN {quoted};", (user,))
            sql_run(cursor, f"GRANT VIEW DATABASE STATE TO {quoted};")
            for grant in SQLSERVER_DATABASE_GRANTS:
                sql_run(cursor, f"GRANT {grant} TO {quoted};")

            installed = sql_scalar(
                cursor,
                "SELECT CASE WHEN OBJECT_ID(N'dbo.lakeflowUtilityVersion') IS NULL THEN NULL ELSE dbo.lakeflowUtilityVersion() END",
            )
            script, version = download_utility_script()
            # Reinstall only for a new version: an upgrade briefly swaps the DDL
            # objects a running gateway depends on.
            if installed != version:
                sql_run(cursor, script)
                print(f"Installed Lakeflow Connect utility objects {version} (was {installed or 'not installed'}).")

            if method == "sqlserver_cdc":
                sql_run(cursor, "EXEC dbo.lakeflowSetupChangeDataCapture @Tables = %s, @User = %s;", (tables, user))
            else:
                sql_run(cursor, "EXEC dbo.lakeflowSetupChangeTracking @Tables = %s, @User = %s, @Retention = '2 DAYS';", (tables, user))
            sql_run(cursor, "EXEC dbo.lakeflowFixPermissions @User = %s, @Tables = %s;", (user, tables))

            if method == "sqlserver_cdc":
                if sql_scalar(cursor, "SELECT is_cdc_enabled FROM sys.databases WHERE database_id = DB_ID()") != 1:
                    fail("cdc", f"CDC is not enabled on database {database}.", cdc_hint())
                cursor.execute(
                    "SELECT OBJECT_NAME(source_object_id), capture_instance FROM cdc.change_tables "
                    "WHERE capture_instance LIKE N'lakeflow[_]%'"
                )
                instances = dict(cursor.fetchall())
                missing = [table for table in SAMPLE_TABLES if table not in instances]
                if missing:
                    fail("cdc", f"no Lakeflow capture instance on {', '.join(missing)}.", cdc_hint())
                tracked = sorted(instances.values())
            else:
                cursor.execute("SELECT OBJECT_NAME(object_id) FROM sys.change_tracking_tables")
                tracked = sorted({row[0] for row in cursor.fetchall()} & set(SAMPLE_TABLES))
                if len(tracked) != len(SAMPLE_TABLES):
                    fail("cdc", f"change tracking is not enabled on every sample table (found {tracked}).", cdc_hint())
            utility_version = sql_scalar(cursor, "SELECT dbo.lakeflowUtilityVersion()")
        connection.close()

        # The ingestion user must be able to sign in and read the tables.
        ingestion = connect(database, user, secret)
        enter("cdc")
        with ingestion.cursor() as cursor:
            for table in SAMPLE_TABLES:
                sql_scalar(cursor, f"SELECT COUNT(*) FROM dbo.{table}")
        ingestion.close()
    except LabCheckFailed:
        raise
    except Exception as error:  # noqa: BLE001 - report the SQL Server error with the stage
        fail("cdc", f"{type(error).__name__}: {error}", cdc_hint())

    result["cdc"] = {
        "status": "ready",
        "method": "cdc" if method == "sqlserver_cdc" else "change_tracking",
        "platform": platform,
        "database": database,
        "tables": [f"dbo.{table}" for table in SAMPLE_TABLES],
        "tracked": tracked,
        "ingestion_user": user,
        "utility_version": utility_version,
    }
    print(f"Lakeflow Connect source ready: {result['cdc']['method']} on {', '.join(result['cdc']['tables'])} for {user}.")


def setup_postgresql_logical(connect):
    database = params["database"]
    user, secret = cdc_credentials()
    tables = [f"public.{table}" for table in SAMPLE_TABLES]
    enter("cdc")
    try:
        connection = connect(database)
        enter("cdc")
        wal_level = connection.run("SHOW wal_level")[0][0]
        if wal_level != "logical":
            fail(
                "cdc",
                f"wal_level is {wal_level}, not logical.",
                "Logical replication comes from the Lakeflow parameter group (rds.logical_replication = 1) "
                "and applies after the instance reboots.",
            )

        def run_formatted(template, *values):
            # format() quotes identifiers (%I) and literals (%L) server-side.
            placeholders = ", ".join(f":v{i}::text" for i in range(len(values)))
            statement = connection.run(
                f"SELECT format(:template::text, {placeholders})", template=template, **{f"v{i}": v for i, v in enumerate(values)}
            )[0][0]
            connection.run(statement)

        exists = connection.run("SELECT 1 FROM pg_roles WHERE rolname = :u", u=user)
        run_formatted("ALTER ROLE %I WITH LOGIN PASSWORD %L" if exists else "CREATE ROLE %I WITH LOGIN PASSWORD %L", user, secret)
        if connection.run("SELECT 1 FROM pg_roles WHERE rolname = 'rds_replication'"):
            run_formatted("GRANT rds_replication TO %I", user)
            platform = "rds"
        else:
            run_formatted("ALTER ROLE %I WITH REPLICATION", user)
            platform = "postgresql"
        run_formatted("GRANT CONNECT ON DATABASE %I TO %I", database, user)
        run_formatted("GRANT USAGE ON SCHEMA public TO %I", user)
        for table in SAMPLE_TABLES:
            run_formatted("GRANT SELECT ON TABLE public.%I TO %I", table, user)
            # The sample tables have primary keys and no large columns.
            run_formatted("ALTER TABLE public.%I REPLICA IDENTITY DEFAULT", table)

        # The publication comes before the slot; the table owner creates it.
        if not connection.run("SELECT 1 FROM pg_publication WHERE pubname = :p", p=POSTGRES_PUBLICATION):
            connection.run(f"CREATE PUBLICATION {POSTGRES_PUBLICATION} FOR TABLE {', '.join(tables)}")
        published_query = "SELECT schemaname || '.' || tablename FROM pg_publication_tables WHERE pubname = :p"
        published = {row[0] for row in connection.run(published_query, p=POSTGRES_PUBLICATION)}
        for table in tables:
            if table not in published:
                connection.run(f"ALTER PUBLICATION {POSTGRES_PUBLICATION} ADD TABLE {table}")

        # The replication user must own the slot. Since PostgreSQL 16 a role's
        # creator is not a member by default, so grant membership for SET ROLE.
        if not connection.run("SELECT 1 FROM pg_replication_slots WHERE slot_name = :s", s=POSTGRES_SLOT):
            run_formatted("GRANT %I TO CURRENT_USER", user)
            run_formatted("SET ROLE %I", user)
            connection.run("SELECT pg_create_logical_replication_slot(:s::name, 'pgoutput')", s=POSTGRES_SLOT)
            connection.run("RESET ROLE")
        slot = connection.run("SELECT plugin, database FROM pg_replication_slots WHERE slot_name = :s", s=POSTGRES_SLOT)
        if not slot or slot[0][0] != "pgoutput" or slot[0][1] != database:
            found = f"plugin {slot[0][0]} on database {slot[0][1]}" if slot else "no slot"
            fail(
                "cdc",
                f"replication slot {POSTGRES_SLOT} must be a pgoutput slot on {database} (found {found}).",
                "Slot names are unique per server: drop or rename the other slot, then rerun ./infra verify.",
            )
        published = sorted(row[0] for row in connection.run(published_query, p=POSTGRES_PUBLICATION))
        connection.close()

        ingestion = connect(database, user, secret)
        enter("cdc")
        for table in tables:
            ingestion.run(f"SELECT count(*) FROM {table}")
        ingestion.close()
    except LabCheckFailed:
        raise
    except Exception as error:  # noqa: BLE001 - report the PostgreSQL error with the stage
        fail("cdc", f"{type(error).__name__}: {error}", cdc_hint())

    result["cdc"] = {
        "status": "ready",
        "method": "logical_replication",
        "platform": platform,
        "database": database,
        "tables": tables,
        "tracked": published,
        "ingestion_user": user,
        "publication": POSTGRES_PUBLICATION,
        "replication_slot": POSTGRES_SLOT,
    }
    print(f"Lakeflow Connect source ready: publication {POSTGRES_PUBLICATION} and slot {POSTGRES_SLOT} for {user}.")



def connect_options_tls():
    # Lab databases use the cloud provider's CA, and PrivateLink hosts do not
    # match the certificate name, so encrypt without verifying the server.
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    return context


def check_mysql():
    mysql = load_driver()
    username, password = credentials()
    context = connect_options_tls()

    def connect(database, user=None, secret=None):
        enter("login")
        login = user or username
        try:
            return mysql.connect(
                host=host, port=port, user=login, password=secret or password, database=database or None,
                ssl=context, connect_timeout=30, read_timeout=120, write_timeout=120, autocommit=True,
            )
        except mysql.err.MySQLError as error:
            fail("login", f"MySQL rejected the connection for {login} ({error}).", login_hint())

    seed = read_seed()
    if seed is not None:
        connection = connect(params["seed_database"] or params["database"])
        enter("seed")
        with connection.cursor() as cursor:
            for statement in split_postgresql(seed):
                cursor.execute(statement)
        connection.close()
        result["seeded"] = True
        print("Sample data loaded.")

    connection = connect(params["database"])
    enter("query")
    with connection.cursor() as cursor:
        if seed is None:
            cursor.execute("SELECT 1")
            result["seeded"] = False
        else:
            rows = {}
            for table in SAMPLE_TABLES:
                cursor.execute(f"SELECT COUNT(*) FROM `{table}`")
                rows[table] = cursor.fetchone()[0]
            result["rows"] = rows
    connection.close()
    if seed is not None and params["cdc_method"] == "mysql_binlog":
        setup_mysql_binlog(mysql, connect)


def setup_mysql_binlog(mysql, connect):
    """Binary log replication for Lakeflow Connect: settings, retention, user, grants."""
    database = params["database"]
    user, secret = cdc_credentials()
    enter("cdc")
    try:
        connection = connect(database)
        enter("cdc")
        with connection.cursor() as cursor:
            cursor.execute(
                "SELECT @@log_bin, @@binlog_format, @@binlog_row_image, "
                "IFNULL(@@binlog_row_value_options, ''), @@version, @@binlog_expire_logs_seconds"
            )
            log_bin, binlog_format, row_image, value_options, version, expire_seconds = cursor.fetchone()
            problems = []
            if int(log_bin) != 1:
                problems.append("binary logging is off")
            if binlog_format != "ROW":
                problems.append(f"binlog_format is {binlog_format}, not ROW")
            if row_image != "FULL":
                problems.append(f"binlog_row_image is {row_image}, not FULL")
            if value_options:
                problems.append(f"binlog_row_value_options is {value_options}, not empty")
            if problems:
                fail(
                    "cdc",
                    "; ".join(problems) + ".",
                    "These come from the server configuration (an RDS parameter group or Azure server parameters, "
                    "which Terraform sets) and may need a restart; on RDS, binary logging also needs automated backups.",
                )

            # RDS purges binary logs right away unless retention is configured.
            cursor.execute(
                "SELECT @@basedir LIKE '/rdsdbbin/%' OR EXISTS (SELECT 1 FROM information_schema.ROUTINES "
                "WHERE ROUTINE_SCHEMA = 'mysql' AND ROUTINE_NAME = 'rds_set_configuration')"
            )
            platform = "rds" if cursor.fetchone()[0] else "mysql"
            if platform == "rds":
                cursor.execute("CALL mysql.rds_set_configuration('binlog retention hours', 168)")
                retention_hours = 168
            else:
                retention_hours = int(expire_seconds) // 3600
                if int(expire_seconds) < 86400:
                    fail("cdc", f"binlog_expire_logs_seconds is {expire_seconds}, below one day (86400).", "Set it to 604800 (seven days) in the server configuration.")

            # MySQL 8 uses caching_sha2_password, the plugin Lakeflow Connect expects.
            plugin = "caching_sha2_password" if not str(version).startswith("5.") else "sha256_password"
            cursor.execute(f"CREATE USER IF NOT EXISTS %s@'%%' IDENTIFIED WITH {plugin} BY %s", (user, secret))
            cursor.execute(f"ALTER USER %s@'%%' IDENTIFIED WITH {plugin} BY %s", (user, secret))
            cursor.execute("GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO %s@'%%'", (user,))
            cursor.execute("GRANT SELECT (plugin, user) ON mysql.user TO %s@'%%'", (user,))
            for table in SAMPLE_TABLES:
                cursor.execute(f"GRANT SELECT ON `{database}`.`{table}` TO %s@'%%'", (user,))
        connection.close()

        ingestion = connect(database, user, secret)
        enter("cdc")
        with ingestion.cursor() as cursor:
            for table in SAMPLE_TABLES:
                cursor.execute(f"SELECT COUNT(*) FROM `{table}`")
                cursor.fetchone()
            # Proves REPLICATION CLIENT: the gateway reads the binary log position.
            try:
                cursor.execute("SHOW BINARY LOG STATUS")
            except mysql.err.MySQLError:
                cursor.execute("SHOW MASTER STATUS")
            position = cursor.fetchone()
        ingestion.close()
        if not position:
            fail("cdc", "the ingestion user cannot read the binary log position.", cdc_hint())
    except LabCheckFailed:
        raise
    except Exception as error:  # noqa: BLE001 - report the MySQL error with the stage
        fail("cdc", f"{type(error).__name__}: {error}", cdc_hint())

    result["cdc"] = {
        "status": "ready",
        "method": "binlog",
        "platform": platform,
        "database": database,
        "tables": [f"{database}.{table}" for table in SAMPLE_TABLES],
        "tracked": [f"{database}.{table}" for table in SAMPLE_TABLES],
        "ingestion_user": user,
        "binlog_retention_hours": retention_hours,
        "mysql_version": str(version),
    }
    print(f"Lakeflow Connect source ready: binary log replication for {user}, {retention_hours}h retention.")


def split_oracle(script):
    """Split on lines that contain only a slash, as SQL*Plus does, and drop the
    comment lines that lead each block so the driver sees the statement first."""
    blocks = []
    for block in re.split(r"(?m)^[\t ]*/[\t ]*$", script):
        lines = block.strip().splitlines()
        while lines and (not lines[0].strip() or lines[0].lstrip().startswith("--")):
            lines.pop(0)
        if lines:
            blocks.append("\n".join(lines).strip())
    return blocks


def check_oracle():
    oracle = load_driver()
    username, password = credentials()

    def connect(service, user=None, secret=None):
        enter("login")
        login = user or username
        try:
            return oracle.connect(user=login, password=secret or password, dsn=f"{host}:{port}/{service}", tcp_connect_timeout=30)
        except oracle.Error as error:
            fail("login", f"Oracle rejected the connection for {login} ({error}).", login_hint())

    seed = read_seed()
    service = params["database"]
    if seed is not None:
        connection = connect(params["seed_database"] or service)
        enter("seed")
        with connection.cursor() as cursor:
            for block in split_oracle(seed):
                cursor.execute(block)
        connection.commit()
        connection.close()
        result["seeded"] = True
        print("Sample data loaded.")

    connection = connect(service)
    enter("query")
    with connection.cursor() as cursor:
        if seed is None:
            cursor.execute("SELECT 1 FROM dual")
            cursor.fetchall()
            result["seeded"] = False
        else:
            rows = {}
            for table in SAMPLE_TABLES:
                cursor.execute(f"SELECT COUNT(*) FROM {ORACLE_SCHEMA}.{table.upper()}")
                rows[table] = cursor.fetchone()[0]
            result["rows"] = rows
    connection.close()
    if seed is not None and params["cdc_method"] == "oracle_logminer":
        setup_oracle_logminer(oracle, connect)


def download_oracle_setup_package():
    import urllib.request

    try:
        with urllib.request.urlopen(ORACLE_SETUP_DOCS_URL, timeout=60) as response:
            page = response.read().decode("utf-8", "replace")
        match = re.search(r"/[A-Za-z0-9/_-]*dbx-oracle-setup-package-[0-9a-f]+\.sql", page)
        if not match:
            fail("cdc", "could not find the dbx-oracle-setup-package.sql link on the Oracle setup page.", f"Check {ORACLE_SETUP_DOCS_URL}.")
        with urllib.request.urlopen("https://docs.databricks.com" + match.group(0), timeout=60) as response:
            script = response.read().decode("utf-8-sig")
    except LabCheckFailed:
        raise
    except Exception as error:  # noqa: BLE001 - report any download failure
        fail(
            "cdc",
            f"could not download the Databricks Oracle setup package ({error}).",
            "The setup downloads it from docs.databricks.com, so this compute needs outbound internet access.",
        )
    if "dbx_oracle_setup_util" not in script:
        fail("cdc", "the downloaded file is not the Databricks Oracle setup package.", cdc_hint())
    return split_oracle(script)


def setup_oracle_logminer(oracle, connect):
    """LogMiner CDC for Lakeflow Connect on a non-multitenant database (Amazon RDS)."""
    service = params["database"]
    user, secret = cdc_credentials()
    user = user.upper()
    if not re.fullmatch(r"[A-Za-z0-9!#$%&*()_=+-]{8,30}", secret):
        fail("cdc", "the ingestion password has characters Oracle cannot take in a quoted password.", cdc_hint())
    tables = [table.upper() for table in SAMPLE_TABLES]
    messages = []

    def output(cursor):
        lines, status = cursor.var(str), cursor.var(int)
        while True:
            cursor.callproc("dbms_output.get_line", (lines, status))
            if status.getvalue() != 0:
                return
            messages.append(lines.getvalue() or "")

    enter("cdc")
    try:
        connection = connect(service)
        enter("cdc")
        with connection.cursor() as cursor:
            cursor.callproc("dbms_output.enable", (None,))
            cursor.execute("SELECT COUNT(*) FROM all_users WHERE username = 'RDSADMIN'")
            rds = cursor.fetchone()[0] > 0
            cursor.execute("SELECT log_mode, supplemental_log_data_min, cdb FROM v$database")
            log_mode, supplemental_min, cdb = cursor.fetchone()
            if log_mode != "ARCHIVELOG":
                fail(
                    "cdc",
                    f"the database is in {log_mode} mode, not ARCHIVELOG.",
                    "On Amazon RDS, archive logging follows automated backups; keep backup retention above zero.",
                )
            if cdb == "YES":
                fail("cdc", "the database is multitenant (CDB).", "Lakeflow Connect does not support multitenant Amazon RDS for Oracle; use a non-CDB engine.")
            if rds:
                # Keep archive logs for 48 hours, as Lakeflow Connect recommends.
                cursor.execute("BEGIN rdsadmin.rdsadmin_util.set_configuration(name => 'archivelog retention hours', value => '48'); END;")
                if supplemental_min == "NO":
                    cursor.execute("BEGIN rdsadmin.rdsadmin_util.alter_supplemental_logging(p_action => 'ADD'); END;")
            elif supplemental_min == "NO":
                cursor.execute("ALTER DATABASE ADD SUPPLEMENTAL LOG DATA")
            for table in tables:
                cursor.execute(
                    "SELECT COUNT(*) FROM all_log_groups WHERE owner = :o AND table_name = :t AND log_group_type = 'ALL COLUMN LOGGING'",
                    o=ORACLE_SCHEMA, t=table,
                )
                if cursor.fetchone()[0] == 0:
                    cursor.execute(f"ALTER TABLE {ORACLE_SCHEMA}.{table} ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS")

            for block in download_oracle_setup_package():
                cursor.execute(block)
            cursor.execute("SELECT status FROM all_objects WHERE object_name = 'DBX_ORACLE_SETUP_UTIL' AND object_type = 'PACKAGE BODY' AND owner = USER")
            status = cursor.fetchone()
            if not status or status[0] != "VALID":
                fail("cdc", "the Databricks Oracle setup package did not compile.", cdc_hint())

            cursor.callproc("dbx_oracle_setup_util.create_user", (user, secret, "USERS", "TEMP"))
            # create_user skips existing users, so set the current password too.
            cursor.execute(f'ALTER USER {user} IDENTIFIED BY "{secret}"')
            cursor.callproc("dbx_oracle_setup_util.grant_permissions", (user,))
            for table in tables:
                cursor.callproc("dbx_oracle_setup_util.grant_select_on_table", (user, ORACLE_SCHEMA, table))
            cursor.callproc("dbx_oracle_setup_util.validate_setup", (user,))
            output(cursor)
            cursor.execute("SELECT supplemental_log_data_min FROM v$database")
            supplemental_min = cursor.fetchone()[0]
        connection.close()

        ingestion = connect(service, user, secret)
        enter("cdc")
        with ingestion.cursor() as cursor:
            for table in tables:
                cursor.execute(f"SELECT COUNT(*) FROM {ORACLE_SCHEMA}.{table}")
                cursor.fetchone()
            cursor.execute("SELECT log_mode FROM v$database")
            cursor.fetchone()
        ingestion.close()
    except LabCheckFailed:
        raise
    except Exception as error:  # noqa: BLE001 - report the Oracle error with the setup package output
        detail = " | ".join(line for line in messages[-8:] if line)
        fail("cdc", f"{type(error).__name__}: {error}" + (f" (setup output: {detail})" if detail else ""), cdc_hint())

    result["cdc"] = {
        "status": "ready",
        "method": "logminer",
        "platform": "rds" if rds else "oracle",
        "database": service,
        "tables": [f"{ORACLE_SCHEMA}.{table}" for table in tables],
        "tracked": [f"{ORACLE_SCHEMA}.{table}" for table in tables],
        "ingestion_user": user,
        "supplemental_log_data_min": supplemental_min,
    }
    print(f"Lakeflow Connect source ready: LogMiner for {user} on {', '.join(result['cdc']['tables'])}.")


# COMMAND ----------

try:
    if params["cdc_method"] and params["cdc_method"] not in CDC_METHODS:
        fail("cdc", f"unknown cdc_method {params['cdc_method']!r}.", f"Use one of {', '.join(CDC_METHODS)}.")
    check_network()
    if engine == "postgresql":
        check_postgresql()
    elif engine == "sqlserver":
        check_sqlserver()
    elif engine == "mysql":
        check_mysql()
    elif engine == "oracle":
        check_oracle()
except LabCheckFailed:
    raise
except Exception as error:  # noqa: BLE001 - classify anything the checks did not anticipate
    fail_unexpected(error)

if "rows" in result:
    print("Row counts: " + ", ".join(f"{table}={count}" for table, count in result["rows"].items()))
result["status"] = "passed"
print(json.dumps(result, indent=2))
dbutils.notebook.exit(json.dumps(result))
