#!/usr/bin/env python3
"""Local, form-based web UI for ./infra (standard library only).

Serves a single page on 127.0.0.1 and exposes a small JSON API that only ever
runs ./infra subcommands, so every safety check of the CLI still applies:
saved plans are reviewed before apply, destroy needs its confirmation token,
and logins open in the operator's own browser. Long operations run in the
background and stream their output to a log file the page tails.

Start it with `./infra ui`.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import threading
import time
import uuid
import webbrowser
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

HERE = Path(__file__).resolve().parent
ROOT = Path(os.environ.get("STS_INFRA_ROOT") or HERE.parent)
sys.path.insert(0, str(ROOT / "lib"))
sys.path.insert(0, str(HERE))
import infra_scenario as scenario  # noqa: E402
import form  # noqa: E402

INFRA = str(ROOT / "infra")
STATIC = HERE / "static"
LOCAL = ROOT / "environments" / "local"
ACTIONS = ("setup", "plan", "apply", "verify", "destroy-plan", "destroy")
TARGET_FLAGS = {
    "description", "aws_account_id", "databricks_account_id", "region", "sso_start_url", "sso_region",
    "sso_role_name", "metastore", "classic_node_type", "subscription_id", "tenant_id", "location",
}
RUNS = {}
RUNS_LOCK = threading.Lock()


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def infra_json(*args, timeout=600):
    """Run ./infra and parse its JSON output; non-zero exits still carry JSON for doctor/explain."""
    result = subprocess.run([INFRA, *args], cwd=ROOT, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
    try:
        payload = json.loads(result.stdout) if result.stdout.strip() else {}
    except ValueError:
        payload = {"output": result.stdout}
    if not isinstance(payload, dict):
        payload = {"items": payload}
    payload["exit_code"] = result.returncode
    if result.returncode != 0 and result.stderr.strip():
        payload["stderr"] = result.stderr.strip()[-4000:]
    return payload


def environment_path(name):
    if not scenario.DEPLOYMENT_ID.match(name) or name == "default":
        raise ApiError(HTTPStatus.BAD_REQUEST, "invalid environment name")
    path = LOCAL / f"{name}.tfvars"
    if not path.is_file():
        raise ApiError(HTTPStatus.NOT_FOUND, f"no environment named {name}")
    return path


def environment_summary(path, targets, deployments):
    name = path.stem
    cloud = form.environment_cloud(path, targets)
    deployed = next((item for item in deployments if item["deployment_id"] == name and item["cloud"] == cloud), None)
    first = path.read_text().splitlines()[:1]
    scenario_text = first[0][len("# Scenario:"):].strip() if first and first[0].startswith("# Scenario:") else ""
    values = scenario.top_level_assignments(path)
    return {
        "name": name,
        "cloud": cloud,
        "tfvars": scenario.display(path),
        "scenario": scenario_text,
        "target": scenario.string_value(values.get("target")),
        "resources": deployed["resources"] if deployed else 0,
        "stage": deployed["stage"] if deployed else None,
        "verify": deployed["verify"] if deployed else None,
        "workspace_url": deployed["workspace_url"] if deployed else None,
        "running": active_run_for(name) is not None,
    }


def list_environments():
    targets = scenario.load_targets()
    deployments = scenario.all_deployments()
    LOCAL.mkdir(parents=True, exist_ok=True)
    return [environment_summary(path, targets, deployments) for path in sorted(LOCAL.glob("*.tfvars"))]


def environment_detail(name):
    path = environment_path(name)
    targets = scenario.load_targets()
    cloud = form.environment_cloud(path, targets)
    values = scenario.top_level_assignments(path)
    target_name = scenario.string_value(values.get("target"))
    target = targets.get(target_name) if target_name else None
    try:
        config, error = scenario.effective_config(cloud, path, target)
    except (OSError, subprocess.SubprocessError) as failure:
        config, error = None, f"could not evaluate the file with Terraform: {failure}"
    detail = {
        "name": name,
        "cloud": cloud,
        "tfvars": scenario.display(path),
        "text": path.read_text(),
        "form": None,
        "error": error,
    }
    if config is not None:
        model = form.form_model(cloud, config, scenario.load_manifest())
        model["target"] = target_name
        model["explicit_region"] = form.REGION_KEY[cloud] in values
        detail["form"] = model
    return detail


def save_environment(name, body):
    path = environment_path(name)
    if "text" in body:
        text = body["text"]
        if not isinstance(text, str) or len(text) > 200_000:
            raise ApiError(HTTPStatus.BAD_REQUEST, "text must be a string")
        path.write_text(text.rstrip("\n") + "\n")
    elif "form" in body:
        model = body["form"]
        cloud = model.get("cloud")
        if cloud not in scenario.CLOUDS:
            raise ApiError(HTTPStatus.BAD_REQUEST, "form.cloud must be aws or azure")
        if model.get("target") and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", model["target"]):
            raise ApiError(HTTPStatus.BAD_REQUEST, "invalid target name")
        if model.get("region") and not re.fullmatch(r"[a-z0-9-]{2,32}", model["region"]):
            raise ApiError(HTTPStatus.BAD_REQUEST, "invalid region")
        if model.get("endpoint_approval") not in (None, "", "auto", "manual"):
            raise ApiError(HTTPStatus.BAD_REQUEST, "endpoint_approval must be auto or manual")
        form.write_form(path, model, scenario.load_manifest())
    else:
        raise ApiError(HTTPStatus.BAD_REQUEST, "send form or text")
    return environment_detail(name)


def create_environment(body):
    cloud, name, template, target = body.get("cloud"), body.get("name", ""), body.get("template", ""), body.get("target")
    if cloud not in scenario.CLOUDS:
        raise ApiError(HTTPStatus.BAD_REQUEST, "cloud must be aws or azure")
    if not scenario.DEPLOYMENT_ID.match(name) or name == "default":
        raise ApiError(HTTPStatus.BAD_REQUEST, "name must match [A-Za-z0-9][A-Za-z0-9._-]{0,127}")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", template):
        raise ApiError(HTTPStatus.BAD_REQUEST, "invalid template")
    args = [INFRA, "new", cloud, name, "--template", template]
    if target:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", target):
            raise ApiError(HTTPStatus.BAD_REQUEST, "invalid target name")
        args += ["--target", target]
    result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, stdin=subprocess.DEVNULL)
    if result.returncode != 0:
        raise ApiError(HTTPStatus.BAD_REQUEST, (result.stderr or result.stdout).strip())
    return {"name": name, "cloud": cloud, "message": result.stdout.strip()}


def add_target(body):
    name, cloud = body.get("name", ""), body.get("cloud")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", name):
        raise ApiError(HTTPStatus.BAD_REQUEST, "invalid target name")
    if cloud not in scenario.CLOUDS:
        raise ApiError(HTTPStatus.BAD_REQUEST, "cloud must be aws or azure")
    args = [INFRA, "targets", "add", name, "--cloud", cloud]
    for key, value in body.items():
        if key in TARGET_FLAGS and value not in (None, ""):
            value = str(value)
            if not re.fullmatch(r"[^\x00-\x1f]{1,256}", value):
                raise ApiError(HTTPStatus.BAD_REQUEST, f"invalid value for {key}")
            args += [f"--{key.replace('_', '-')}", value]
    result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, stdin=subprocess.DEVNULL)
    if result.returncode != 0:
        raise ApiError(HTTPStatus.BAD_REQUEST, (result.stderr or result.stdout).strip())
    return {"message": result.stdout.strip()}


def plan_summary(name, cloud, kind):
    path = ROOT / ".artifacts" / cloud / name / f"{kind}.tfplan.summary.json"
    plan = ROOT / ".artifacts" / cloud / name / f"{kind}.tfplan"
    if not path.is_file() or not plan.is_file() or Path(f"{plan}.applied").exists() or Path(f"{plan}.failed").exists():
        return None
    summary = scenario.read_json(path) or {}
    summary["created"] = plan.stat().st_mtime
    summary["fresh"] = time.time() - plan.stat().st_mtime < scenario.FRESH_PLAN_SECONDS
    return summary


# --- background runs ----------------------------------------------------------


def active_run_for(name):
    with RUNS_LOCK:
        for run in RUNS.values():
            if run["environment"] == name and run["exit_code"] is None:
                return run["id"]
    return None


def start_run(name, body):
    path = environment_path(name)
    action = body.get("action")
    if action not in ACTIONS:
        raise ApiError(HTTPStatus.BAD_REQUEST, f"action must be one of {', '.join(ACTIONS)}")
    if active_run_for(name):
        raise ApiError(HTTPStatus.CONFLICT, "another operation is still running for this environment")
    cloud = form.environment_cloud(path, scenario.load_targets())
    shown = scenario.display(path)
    args = [INFRA, action, cloud, shown]
    if action == "setup":
        args.append("--yes")
        if body.get("force_login"):
            args.append("--force-login")
    if action == "apply":
        summary = plan_summary(name, cloud, "apply")
        if summary is None:
            raise ApiError(HTTPStatus.CONFLICT, "create and review a plan first")
        if body.get("confirm") != "apply":
            raise ApiError(HTTPStatus.BAD_REQUEST, "confirm the reviewed plan summary first")
    if action == "destroy":
        if plan_summary(name, cloud, "destroy") is None:
            raise ApiError(HTTPStatus.CONFLICT, "create and review a destroy plan first")
        token = f"destroy-{cloud}"
        if body.get("confirm") != token:
            raise ApiError(HTTPStatus.BAD_REQUEST, f"type {token} to confirm")
        args += ["--confirm", token]
    log_dir = ROOT / ".artifacts" / cloud / name / "ui"
    log_dir.mkdir(parents=True, exist_ok=True)
    log_path = log_dir / f"{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}-{action}.log"
    run_id = uuid.uuid4().hex[:12]
    run = {
        "id": run_id, "environment": name, "cloud": cloud, "action": action, "command": " ".join(["./infra", *args[1:]]),
        "started": time.time(), "finished": None, "exit_code": None, "log": scenario.display(log_path),
    }
    with RUNS_LOCK:
        RUNS[run_id] = run
    log_file = open(log_path, "w", buffering=1)
    log_file.write(f"$ {run['command']}\n")
    env = dict(os.environ, TF_IN_AUTOMATION="1")
    process = subprocess.Popen(args, cwd=ROOT, stdout=log_file, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env)

    def wait():
        code = process.wait()
        log_file.write(f"\n[exit {code}]\n")
        log_file.close()
        with RUNS_LOCK:
            run["exit_code"] = code
            run["finished"] = time.time()

    threading.Thread(target=wait, daemon=True).start()
    return run


def run_state(run_id, offset):
    with RUNS_LOCK:
        run = RUNS.get(run_id)
        if run is None:
            raise ApiError(HTTPStatus.NOT_FOUND, "unknown run")
        state = dict(run)
    log_path = ROOT / state["log"]
    text = log_path.read_text() if log_path.exists() else ""
    state["offset"] = len(text)
    state["chunk"] = text[offset:] if offset <= len(text) else text
    return state


# --- HTTP ----------------------------------------------------------------------


class Handler(BaseHTTPRequestHandler):
    server_version = "sts-infra-ui/1"

    def log_message(self, fmt, *args):
        if os.environ.get("STS_INFRA_UI_DEBUG"):
            super().log_message(fmt, *args)

    def send_json(self, payload, status=HTTPStatus.OK):
        data = json.dumps(payload, indent=2).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length > 1_000_000:
            raise ApiError(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "request too large")
        if self.headers.get("Content-Type", "").split(";")[0].strip() != "application/json":
            raise ApiError(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, "send application/json")
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            raise ApiError(HTTPStatus.BAD_REQUEST, "invalid JSON")
        if not isinstance(body, dict):
            raise ApiError(HTTPStatus.BAD_REQUEST, "expected a JSON object")
        return body

    def serve_static(self, name):
        path = (STATIC / name).resolve()
        if not path.is_file() or STATIC not in path.parents:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        types = {".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css"}
        data = path.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", types.get(path.suffix, "application/octet-stream"))
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlparse(self.path)
        query = {key: values[-1] for key, values in parse_qs(url.query).items()}
        parts = [part for part in url.path.split("/") if part]
        try:
            if not parts:
                return self.serve_static("index.html")
            if parts[0] != "api":
                return self.serve_static("/".join(parts))
            self.send_json(self.api_get(parts[1:], query))
        except ApiError as error:
            self.send_json({"error": str(error)}, error.status)
        except subprocess.TimeoutExpired:
            self.send_json({"error": "./infra did not answer in time"}, HTTPStatus.GATEWAY_TIMEOUT)
        except Exception as failure:  # keep the page alive; the message is shown to the user
            self.send_json({"error": f"{type(failure).__name__}: {failure}"}, HTTPStatus.INTERNAL_SERVER_ERROR)

    def do_POST(self):
        self.do_write("POST")

    def do_PUT(self):
        self.do_write("PUT")

    def do_write(self, method):
        parts = [part for part in urlparse(self.path).path.split("/") if part]
        try:
            body = self.read_body()
            self.send_json(self.api_write(method, parts[1:] if parts[:1] == ["api"] else None, body))
        except ApiError as error:
            self.send_json({"error": str(error)}, error.status)
        except Exception as failure:
            self.send_json({"error": f"{type(failure).__name__}: {failure}"}, HTTPStatus.INTERNAL_SERVER_ERROR)

    def api_get(self, parts, query):
        if parts == ["manifest"]:
            return scenario.load_manifest()
        if parts == ["templates"]:
            return infra_json("templates", "--json")
        if parts == ["targets"]:
            return infra_json("targets", "--json")
        if parts == ["deployments"]:
            return infra_json("ls", "--all", "--json")
        if parts == ["environments"]:
            return {"environments": list_environments()}
        if len(parts) >= 2 and parts[0] == "environments":
            name = parts[1]
            path = environment_path(name)
            cloud = form.environment_cloud(path, scenario.load_targets())
            shown = scenario.display(path)
            rest = parts[2:]
            if not rest:
                return environment_detail(name)
            if rest == ["explain"]:
                return infra_json("explain", cloud, shown, "--json")
            if rest == ["doctor"]:
                return infra_json("doctor", cloud, shown, "--json", timeout=120)
            if rest == ["status"]:
                return infra_json("status", cloud, shown, "--json")
            if rest == ["output"]:
                return infra_json("output", cloud, shown, "--json")
            if rest == ["plans"]:
                return {"apply": plan_summary(name, cloud, "apply"), "destroy": plan_summary(name, cloud, "destroy"),
                        "verify": scenario.read_json(ROOT / ".artifacts" / cloud / name / "verify.json")}
            if rest == ["endpoints"]:
                result = subprocess.run([INFRA, "endpoints", cloud, "status", shown], cwd=ROOT, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=300)
                return {"exit_code": result.returncode, "output": (result.stdout + result.stderr)[-20000:]}
        if len(parts) == 2 and parts[0] == "runs":
            return run_state(parts[1], int(query.get("offset", "0") or 0))
        raise ApiError(HTTPStatus.NOT_FOUND, "unknown API path")

    def api_write(self, method, parts, body):
        if parts is None:
            raise ApiError(HTTPStatus.NOT_FOUND, "unknown API path")
        if method == "POST" and parts == ["environments"]:
            return create_environment(body)
        if method == "POST" and parts == ["targets"]:
            return add_target(body)
        if len(parts) == 2 and parts[0] == "environments" and method == "PUT":
            return save_environment(parts[1], body)
        if len(parts) == 3 and parts[0] == "environments" and parts[2] == "run" and method == "POST":
            return start_run(parts[1], body)
        raise ApiError(HTTPStatus.NOT_FOUND, "unknown API path")


def serve(port, open_browser):
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    url = f"http://127.0.0.1:{server.server_address[1]}/"
    print(f"sts-infra UI: {url}  (Ctrl+C stops it; it only listens on this machine)")
    if open_browser:
        threading.Timer(0.5, webbrowser.open, [url]).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        server.server_close()


def main(argv=None):
    parser = argparse.ArgumentParser(prog="./infra ui", description="local form-based UI for ./infra")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--no-browser", action="store_true", help="do not open the page automatically")
    args = parser.parse_args(argv)
    serve(args.port, not args.no_browser)
    return 0


if __name__ == "__main__":
    sys.exit(main())
