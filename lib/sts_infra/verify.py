"""./infra verify: copy credentials, wait for serverless rules, run the lab check job, report each path."""
from __future__ import annotations

import json
import os
import re
import time

from . import auth, clis
from .common import is_seconds, EXIT_USAGE, EXIT_VERIFY_FAILED, die, env_int, err, out, parse_json, utc_now
from .context import Context, jq_tostring

FAILURE = re.compile(r"LAB CHECK FAILED at (?P<stage>[a-z]+): (?P<message>.*?) Hint: (?P<hint>.*)")
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def present(value) -> bool:
    """jq truthiness: only null and false are empty."""
    return value is not None and value is not False


def alternative(*values):
    """jq's a // b // c."""
    return next((value for value in values if present(value)), None)


def text(value) -> str:
    """jq string interpolation: null renders as "null"."""
    if value is None:
        return "null"
    if isinstance(value, str):
        return value
    return json.dumps(value, separators=(",", ":")) if isinstance(value, (dict, list)) else jq_tostring(value) or str(value).lower()


def sync_lab_check_credentials(ctx: Context, workspace_url: str, lab: dict) -> None:
    """Copy each database's credentials from Secrets Manager into the lab check secret scope.

    Values travel through process pipes only: never printed, logged, or passed as an argument.
    """
    scope = lab.get("secret_scope") or ""
    if ctx.cloud != "aws" or not scope:
        return
    for entry in lab.get("credentials") or []:
        source, arn = entry.get("source"), entry.get("secret_arn")
        secret = None
        for field in ("username", "password"):
            key = entry.get(f"{field}_key")
            if secret is None:
                code, payload = clis.aws_cli(ctx, "secretsmanager", "get-secret-value", "--secret-id", arn, "--query", "SecretString", "--output", "text")
                secret = parse_json(payload) if code == 0 else None
                payload = None
            value = secret.get(field) if isinstance(secret, dict) else None
            if not isinstance(value, str):
                err(f"the secret has no {field}")
                die(f"could not copy the {source} {field} into secret scope {scope}")
            code, _ = clis.databricks_workspace_cli(ctx, workspace_url, "secrets", "put-secret", scope, key, input=value, stdout="null")
            if code != 0:
                die(f"could not copy the {source} {field} into secret scope {scope}")
        secret = None
        err(f"Copied the {source} credentials into secret scope {scope}.")


def wait_for_serverless_rules(ctx: Context, outputs: dict, lab: dict, wait_seconds: int) -> None:
    """Serverless checks fail until Databricks reports the private endpoint rules ESTABLISHED."""
    if not any((check or {}).get("compute") == "serverless" for check in (lab.get("checks") or {}).values()):
        return
    connectivity = (outputs.get("serverless_connectivity") or {}).get("value") or {}
    ncc = connectivity.get("network_connectivity_config_id") or ""
    rule_ids = [rule.get("rule_id") for rule in (connectivity.get("rules") or {}).values() if isinstance(rule, dict) and rule.get("rule_id") is not None]
    if not ncc or not rule_ids or wait_seconds <= 0:
        return
    from .common import items_of

    deadline = time.time() + wait_seconds
    while True:
        code, payload = clis.databricks_account_cli(ctx, "account", "network-connectivity", "list-private-endpoint-rules", ncc, "--output", "json", stderr="null")
        listed = parse_json(payload) if code == 0 else None
        if listed is None:
            err("WARNING: could not read the NCC private endpoint rules; running the checks anyway.")
            return
        pending = [
            f"{text(alternative(rule.get('resource_id'), rule.get('endpoint_service'), rule.get('rule_id')))}={text(alternative(rule.get('connection_state'), 'UNKNOWN'))}"
            for rule in items_of(listed, "items", "rules")
            if isinstance(rule, dict) and rule.get("rule_id") in rule_ids and alternative(rule.get("connection_state"), "UNKNOWN") != "ESTABLISHED"
        ]
        if not pending:
            err("Serverless private endpoint rules are ESTABLISHED.")
            return
        if time.time() >= deadline:
            err("WARNING: serverless private endpoint rules are not ESTABLISHED yet; serverless checks may fail:")
            for item in pending:
                err(f"  {item}")
            return
        err("Waiting for serverless private endpoint rules to become ESTABLISHED: " + "".join(f"{item} " for item in pending))
        time.sleep(env_int("STS_INFRA_VERIFY_INTERVAL", 30))


def latest_attempts(run: dict) -> list:
    """Retried tasks appear once per attempt; keep the latest attempt of each, ordered by task key."""
    latest: dict = {}
    for task in run.get("tasks") or []:
        key = task.get("task_key")
        if key not in latest or (task.get("attempt_number") or 0) >= (latest[key].get("attempt_number") or 0):
            latest[key] = task
    return [latest[key] for key in sorted(latest, key=lambda k: (k is None, k or ""))]


def check_result(task_key: str, task_run: str, run: dict, output: dict, lab: dict) -> dict:
    state = next((task for task in run.get("tasks") or [] if jq_tostring(task.get("run_id")) == task_run), {}) or {}
    task_state = state.get("state") or {}
    check = (lab.get("checks") or {}).get(task_key) or {}
    result = parse_json(alternative((output.get("notebook_output") or {}).get("result"), "") or "", {})
    result = result if isinstance(result, dict) else {}
    message = alternative(output.get("error"), task_state.get("state_message"), "")
    match = FAILURE.search(message) if isinstance(message, str) else None
    failure = match.groupdict() if match else {}
    result_state = task_state.get("result_state")
    succeeded = result_state == "SUCCESS"
    if succeeded and result.get("status") == "passed":
        status = "passed"
    elif result_state in ("UPSTREAM_FAILED", "EXCLUDED"):
        status = "skipped"
    else:
        status = "failed"
    trace = None
    if not succeeded and not failure.get("stage"):
        lines = [line for line in ANSI.sub("", alternative(output.get("error_trace"), "") or "").split("\n") if re.search(r"\S", line)]
        trace = "\n".join(lines[-12:]) or None
    return {
        "check": task_key,
        "source": check.get("source"),
        "compute": check.get("compute"),
        "mode": check.get("mode"),
        "engine": check.get("engine"),
        "status": status,
        "rows": alternative(result.get("rows")),
        "seeded": alternative(result.get("seeded")),
        "cdc": alternative(result.get("cdc")),
        "stage": failure.get("stage"),
        "error": None if succeeded else alternative(failure.get("message"), output.get("error"), task_state.get("state_message"), "the task did not finish"),
        "hint": failure.get("hint"),
        # Unclassified failures keep the end of the traceback so the cause is visible without opening the run.
        "trace": trace,
    }


def render_check(check: dict) -> str:
    status = check["status"]
    tag = "[pass]" if status == "passed" else "[skip]" if status == "skipped" else "[FAIL]"
    line = f"  {tag} {text(check['source'])} from {text(check['compute'])} compute over {text(check['mode'])}"
    if status == "passed":
        rows = check.get("rows")
        if present(rows):
            line += ": sample data " + ", ".join(f"{key}={text(value)}" for key, value in rows.items()) if isinstance(rows, dict) else ": sample data "
        else:
            line += ": reachable"
        cdc = check.get("cdc")
        if present(cdc):
            cdc = cdc if isinstance(cdc, dict) else {}
            line += "; Lakeflow Connect " + (cdc.get("method") or "") + " ready for " + (cdc.get("ingestion_user") or "")
    else:
        line += ": " + ((check["stage"] + ": ") if present(check.get("stage")) else "") + (check.get("error") if present(check.get("error")) else "")
    if present(check.get("hint")):
        line += "\n         hint: " + check["hint"]
    if present(check.get("trace")):
        line += "\n         traceback (last lines):\n" + "\n".join("           " + part for part in check["trace"].split("\n"))
    return line


def verify_deployment(ctx: Context, cloud: str, vars_path: str, json_mode: bool, endpoint_wait: int) -> int:
    ctx.prepare(cloud, vars_path)
    ctx.check_legacy_state()
    ctx.bind()
    if not ctx.state_exists():
        die(f"state not found for deployment '{ctx.id}'; plan and apply it first")
    ctx.acquire_lock()
    auth.preflight(ctx, "verify", write=err)
    outputs = ctx.terraform_output_json()
    if not isinstance(outputs, dict):
        die("could not read Terraform outputs")
    lab = (outputs.get("lab_check") or {}).get("value")
    if not lab:
        if (outputs.get("deployment_stage") or {}).get("value") == "foundation":
            die(f"the lab check job is added by the second deployment stage: run {ctx.setup_fix()}, then ./infra plan and ./infra apply")
        die("this deployment has no lab check job. It exists when the workspace is enabled, lab_check.enabled is not false, "
            "and at least one source has a classic or serverless path")
    workspace_url = ctx.state_workspace_url()
    job_id = jq_tostring(lab.get("job_id")) or "null"

    sync_lab_check_credentials(ctx, workspace_url, lab)
    wait_for_serverless_rules(ctx, outputs, lab, endpoint_wait)

    code, payload = clis.databricks_workspace_cli(ctx, workspace_url, "jobs", "run-now", job_id, "--no-wait", "--output", "json")
    started = parse_json(payload, {}) if code == 0 else {}
    run_id = jq_tostring(started.get("run_id")) if isinstance(started, dict) else ""
    if not run_id:
        die(f"could not start the lab check job {job_id}")
    err(f"Started lab check run {run_id}. Classic checks start a small cluster, which takes about 5 minutes.")
    deadline = time.time() + env_int("STS_INFRA_VERIFY_TIMEOUT", 3600)
    while True:
        code, payload = clis.databricks_workspace_cli(ctx, workspace_url, "jobs", "get-run", run_id, "--output", "json")
        run = parse_json(payload) if code == 0 else None
        if not isinstance(run, dict):
            die(f"could not read lab check run {run_id}")
        if (run.get("state") or {}).get("life_cycle_state") in ("TERMINATED", "SKIPPED", "INTERNAL_ERROR"):
            break
        if time.time() >= deadline:
            die(f"lab check run {run_id} did not finish in time; see {run.get('run_page_url') or ''}")
        states = " ".join(f"{text(task.get('task_key'))}={text(alternative((task.get('state') or {}).get('result_state'), (task.get('state') or {}).get('life_cycle_state')))}"
                          for task in run.get("tasks") or [])
        err(f"  {states}")
        time.sleep(env_int("STS_INFRA_VERIFY_INTERVAL", 30))

    results = []
    for task in latest_attempts(run):
        task_key, task_run = task.get("task_key"), jq_tostring(task.get("run_id"))
        if not task_key:
            continue
        code, payload = clis.databricks_workspace_cli(ctx, workspace_url, "jobs", "get-run-output", task_run, "--output", "json", stderr="null")
        # A task still being retried can return an empty or partial body.
        output = parse_json(payload) if code == 0 else None
        results.append(check_result(task_key, task_run, run, output if isinstance(output, dict) else {}, lab))

    status = "passed" if results and all(check["status"] == "passed" for check in results) else "failed"
    summary = {
        "version": 1, "cloud": ctx.cloud, "deployment_id": ctx.id, "status": status, "checked_at": utc_now(),
        "run_id": run.get("run_id"), "run_url": alternative(run.get("run_page_url")), "job_url": alternative(lab.get("job_url")), "checks": results,
    }
    rendered = json.dumps(summary, indent=2, ensure_ascii=False)
    old_umask = os.umask(0o077)
    try:
        with open(f"{ctx.artifacts}/verify.json", "w") as handle:
            handle.write(rendered + "\n")
    finally:
        os.umask(old_umask)

    if json_mode:
        out(rendered)
    else:
        label = summary["run_url"] if present(summary["run_url"]) else f"run {text(summary['run_id'])}"
        out(f"Lab check results for {ctx.cloud}/{ctx.id} ({label}):")
        for check in results:
            out(render_check(check))
        if status == "passed":
            out("All network paths work.")
        else:
            out(f"Some checks failed. Fix the path, then rerun: ./infra verify {ctx.cloud} {ctx.display_vars}")
    return 0 if status == "passed" else EXIT_VERIFY_FAILED


def verify_command(ctx: Context, args: list) -> int:
    from .common import Usage
    from .context import cloud_root

    if len(args) < 2:
        raise Usage()
    cloud, vars_path, rest = args[0], args[1], args[2:]
    cloud_root(cloud)
    json_mode, wait = False, 900
    while rest:
        arg = rest.pop(0)
        if arg == "--json":
            json_mode = True
        elif arg == "--endpoint-wait":
            if not rest or not is_seconds(rest[0]):
                die("--endpoint-wait requires a number of seconds", EXIT_USAGE)
            wait = int(rest.pop(0))
        else:
            raise Usage()
    return verify_deployment(ctx, cloud, vars_path, json_mode, wait)
