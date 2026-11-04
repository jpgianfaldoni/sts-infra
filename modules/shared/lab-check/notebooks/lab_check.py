# Databricks notebook source
# MAGIC %md
# MAGIC # sts-infra lab check
# MAGIC
# MAGIC Created by Terraform and run by `./infra verify`. Each task checks one
# MAGIC compute path (classic or serverless) to one data source:
# MAGIC
# MAGIC 1. resolves the source host and opens a TCP connection over the private path;
# MAGIC 2. for databases, loads the sample data idempotently and counts the rows.
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
}
TCP_TIMEOUT_SECONDS = 15
SAMPLE_TABLES = ("customers", "orders")

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


def credentials():
    enter("credentials")
    try:
        username = dbutils.secrets.get(scope=params["secret_scope"], key=params["username_key"])
        password = dbutils.secrets.get(scope=params["secret_scope"], key=params["password_key"])
    except Exception as error:  # noqa: BLE001 - surface any secret lookup failure
        fail(
            "credentials",
            f"could not read {params['username_key']}/{params['password_key']} from secret scope {params['secret_scope']} ({type(error).__name__}).",
            f"./infra verify {cloud} <tfvars> copies the credentials into the scope before it runs this job.",
        )
    return username, password


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

    def connect(database):
        enter("login")
        try:
            return pg.Connection(
                username, host=host, port=port, database=database, password=password, ssl_context=context, timeout=60
            )
        except (pg.DatabaseError, pg.InterfaceError) as error:
            fail("login", f"PostgreSQL rejected the connection ({error}).", login_hint())

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


def check_sqlserver():
    mssql = load_driver()
    username, password = credentials()

    def connect(database):
        enter("login")
        users = [username]
        # Azure SQL Database also accepts the user@server form some drivers need.
        if host.endswith(".database.windows.net") and "@" not in username:
            users.append(f"{username}@{host.split('.')[0]}")
        error = None
        for user in users:
            try:
                return mssql.connect(
                    server=host,
                    port=port,
                    user=user,
                    password=password,
                    database=database,
                    login_timeout=30,
                    timeout=120,
                    autocommit=True,
                )
            except mssql.Error as caught:
                error = caught
        fail("login", f"SQL Server rejected the connection ({error}).", login_hint())

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


# COMMAND ----------

try:
    check_network()
    if engine == "postgresql":
        check_postgresql()
    elif engine == "sqlserver":
        check_sqlserver()
except LabCheckFailed:
    raise
except Exception as error:  # noqa: BLE001 - classify anything the checks did not anticipate
    fail_unexpected(error)

if "rows" in result:
    print("Row counts: " + ", ".join(f"{table}={count}" for table, count in result["rows"].items()))
result["status"] = "passed"
print(json.dumps(result, indent=2))
dbutils.notebook.exit(json.dumps(result))
