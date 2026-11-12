"""Serverless private endpoint approval on AWS (endpoint services) and Azure (private links).

Only the connections this deployment requested are ever accepted, matched by
the endpoint ID or name Databricks reports for each rule. Connections from
anyone else, including other customers using the shared serverless role, are
never accepted.
"""
from __future__ import annotations

import json
import time

from . import auth, clis
from .common import Usage, die, env_int, err, items_of, out, parse_json
from .context import Context


def wait_interval(default: int = 15) -> int:
    return env_int("STS_INFRA_WAIT_INTERVAL", default)


def approve_after_apply(ctx: Context) -> bool:
    if ctx.endpoint_approval_mode() != "auto":
        return True
    from .common import Exit

    try:
        return aws_accept_serverless_endpoints(ctx) if ctx.cloud == "aws" else azure_approve_serverless_endpoints(ctx)
    except Exit as stop:  # the apply already succeeded; report and let the caller warn
        if stop.message:
            err(f"ERROR: {stop.message}")
        return False


def connection_state(ctx: Context, service_id: str, endpoint_id: str):
    code, text = clis.aws_cli(ctx, "ec2", "describe-vpc-endpoint-connections", "--filters", f"Name=service-id,Values={service_id}", "--output", "json")
    listed = parse_json(text) if code == 0 else None
    if not isinstance(listed, dict):
        return None
    return next((c.get("VpcEndpointState") for c in listed.get("VpcEndpointConnections") or [] if c.get("VpcEndpointId") == endpoint_id), "missing")


def aws_accept_serverless_endpoints(ctx: Context) -> bool:
    outputs = ctx.terraform_output_json()
    if not isinstance(outputs, dict):
        return False
    pending = [dict(item) for item in ((outputs.get("pending_endpoint_acceptances") or {}).get("value") or []) if isinstance(item, dict) and item.get("service_id") is not None]
    if not pending:
        return True
    connectivity = (outputs.get("serverless_connectivity") or {}).get("value") or {}
    ncc = connectivity.get("network_connectivity_config_id") or ""
    rules = {name: (rule or {}).get("rule_id") for name, rule in (connectivity.get("rules") or {}).items()}
    out("Accepting the serverless NCC endpoint connections this deployment requested (endpoint_approval = \"auto\").")
    deadline = time.time() + env_int("STS_INFRA_ENDPOINT_WAIT", 600)
    while True:
        if ncc and any(item.get("endpoint_id") is None for item in pending):
            code, text = clis.databricks_account_cli(ctx, "account", "network-connectivity", "list-private-endpoint-rules", ncc, "--output", "json", stderr="null")
            listed = parse_json(text) if code == 0 else None
            if listed is not None:
                live = items_of(listed, "items", "rules")
                for item in pending:
                    if item.get("endpoint_id") is None:
                        rule_id = rules.get(item.get("component"))
                        item["endpoint_id"] = next((r.get("vpc_endpoint_id") for r in live if isinstance(r, dict) and r.get("rule_id") == rule_id and r.get("vpc_endpoint_id")), None)
        waiting = 0
        for item in pending:
            service_id, endpoint_id = item["service_id"], item.get("endpoint_id") or ""
            if not endpoint_id:
                waiting += 1
                continue
            state = connection_state(ctx, service_id, endpoint_id)
            if state is None:
                return False
            if state == "pendingAcceptance":
                code, text = clis.aws_cli(ctx, "ec2", "accept-vpc-endpoint-connections", "--service-id", service_id, "--vpc-endpoint-ids", endpoint_id, "--output", "json")
                result = parse_json(text) if code == 0 else None
                if not isinstance(result, dict):
                    return False
                if result.get("Unsuccessful"):
                    err(f"WARNING: AWS did not accept {endpoint_id} on {service_id}: {json.dumps(result.get('Unsuccessful'), separators=(',', ':'))}")
                    return False
                out(f"  accepted {endpoint_id} on {service_id}")
                waiting += 1
            elif state in ("available", "pending"):
                pass
            elif state == "missing":
                waiting += 1
            else:
                err(f"WARNING: serverless endpoint connection {endpoint_id} on {service_id} is {state}")
                return False
        if waiting == 0:
            break
        if time.time() >= deadline:
            err(f"WARNING: {waiting} serverless connection(s) were not requested or accepted in time")
            return False
        time.sleep(wait_interval())
    out("Serverless endpoint connections accepted. Databricks marks the rules ESTABLISHED a few minutes later.")
    return True


def reject_serverless_endpoints_before_destroy(ctx: Context) -> None:
    """AWS cannot delete an endpoint service while a consumer endpoint is connected.

    The typed destroy confirmation covers rejecting the serverless connections
    on this deployment's own endpoint services (connections from other
    accounts; classic endpoints in this account are deleted by Terraform).
    """
    if ctx.endpoint_approval_mode() != "auto":
        out("endpoint_approval = \"manual\": reject active serverless endpoint connections yourself (./infra endpoints aws status) "
            "if Terraform cannot delete an endpoint service.")
        return
    outputs = ctx.terraform_output_json()
    if not isinstance(outputs, dict):
        die("could not read the endpoint services from Terraform state before destroy")
    service_ids = sorted({
        (path.get("serverless") or {}).get("endpoint_service_id")
        for path in ((outputs.get("connectivity") or {}).get("value") or {}).values()
        if isinstance(path, dict) and (path.get("serverless") or {}).get("mode") == "private_link" and (path.get("serverless") or {}).get("endpoint_service_id")
    })
    if not service_ids:
        return
    deadline = time.time() + env_int("STS_INFRA_ENDPOINT_WAIT", 600)
    while True:
        remaining = 0
        for service_id in service_ids:
            code, text = clis.aws_cli(ctx, "ec2", "describe-vpc-endpoint-connections", "--filters", f"Name=service-id,Values={service_id}", "--output", "json")
            listed = parse_json(text) if code == 0 else None
            if not isinstance(listed, dict):
                die(f"could not list the serverless endpoint connections on {service_id}; Terraform destroy was not started")
            for connection in listed.get("VpcEndpointConnections") or []:
                if connection.get("VpcEndpointOwner") == ctx.aws_account:
                    continue
                if connection.get("VpcEndpointState") not in ("available", "pendingAcceptance", "pending"):
                    continue
                endpoint_id = connection.get("VpcEndpointId")
                remaining += 1
                code, text = clis.aws_cli(ctx, "ec2", "reject-vpc-endpoint-connections", "--service-id", service_id, "--vpc-endpoint-ids", endpoint_id, "--output", "json")
                result = parse_json(text) if code == 0 else None
                if not isinstance(result, dict) or result.get("Unsuccessful"):
                    die(f"could not reject serverless endpoint connection {endpoint_id} on {service_id}; Terraform destroy was not started")
                out(f"Rejected serverless endpoint connection {endpoint_id} on {service_id}.")
        if remaining == 0:
            return
        if time.time() >= deadline:
            die("serverless endpoint connections are still active after rejection; Terraform destroy was not started")
        time.sleep(wait_interval())


def azure_endpoint_status(ctx: Context) -> list:
    """The NCC private endpoints in state, matched with the live connection on each target resource."""
    outputs = ctx.terraform_output_json()
    if not isinstance(outputs, dict):
        die("could not read the pending endpoint approvals from Terraform state")
    pending = [item for item in (outputs.get("pending_endpoint_approvals") or {}).get("value") or [] if isinstance(item, dict)]
    connections = []
    seen = []
    for item in pending:
        resource_id = item.get("resource_id")
        if not resource_id or resource_id in seen:
            continue
        seen.append(resource_id)
        code, text = ctx.call(["az", "network", "private-endpoint-connection", "list", "--id", resource_id, "--output", "json"], stderr="null")
        listed = parse_json(text) if code == 0 else None
        if not isinstance(listed, list):
            die(f"could not list private endpoint connections for {resource_id}")
        connections += [c for c in listed if isinstance(c, dict)]
    status = []
    for item in pending:
        name = (item.get("endpoint_name") or "").lower()
        connection = next((c for c in connections
                           if (((c.get("properties") or {}).get("privateEndpoint") or {}).get("id") or "").split("/")[-1].lower() == name), None)
        state = (((connection or {}).get("properties") or {}).get("privateLinkServiceConnectionState") or {}).get("status")
        status.append({**item, "connection_id": (connection or {}).get("id"), "azure_status": state or "NotFound"})
    return status


def decide_azure_endpoint(ctx: Context, decision: str, connection_id: str) -> dict:
    verb = "Approved" if decision == "approve" else "Rejected"
    if not any(item.get("connection_id") == connection_id for item in azure_endpoint_status(ctx)):
        die(f"connection {connection_id} is not a private endpoint connection managed by this deployment; see ./infra endpoints azure status {ctx.display_vars}")
    code, text = ctx.call(["az", "network", "private-endpoint-connection", decision, "--id", connection_id,
                           "--description", f"{verb} with ./infra for deployment {ctx.id}", "--output", "json"])
    result = parse_json(text) if code == 0 else None
    if not isinstance(result, dict):
        die(f"Azure did not {decision} {connection_id}")
    return {"id": result.get("id"), "status": ((result.get("properties") or {}).get("privateLinkServiceConnectionState") or {}).get("status")}


def azure_approve_serverless_endpoints(ctx: Context) -> bool:
    status = azure_endpoint_status(ctx)
    if not status:
        return True
    out("Approving the serverless NCC private endpoint connections this deployment requested (endpoint_approval = \"auto\").")
    deadline = time.time() + env_int("STS_INFRA_ENDPOINT_WAIT", 600)
    while True:
        for item in status:
            if item.get("azure_status") != "Pending" or not item.get("connection_id"):
                continue
            result = decide_azure_endpoint(ctx, "approve", item["connection_id"])
            if result.get("status") != "Approved":
                err(f"WARNING: Azure did not approve {item['connection_id']}: {json.dumps(result, separators=(',', ':'))}")
                return False
            out(f"  approved {item['connection_id']}")
        waiting = len([item for item in status if item.get("connection_id") is None])
        if waiting == 0:
            break
        if time.time() >= deadline:
            err(f"WARNING: {waiting} private endpoint connection(s) have not appeared yet; approve them later with ./infra endpoints azure status {ctx.display_vars}")
            return True
        out(f"  waiting for Databricks to create {waiting} private endpoint(s)...")
        time.sleep(wait_interval())
        status = azure_endpoint_status(ctx)
    out("Private endpoint connections approved. Databricks marks the rules ESTABLISHED a few minutes later.")
    return True


def print_json(value) -> None:
    out(json.dumps(value, indent=2, ensure_ascii=False))


def endpoints_command(ctx: Context, args: list) -> None:
    cloud = args[0] if args else ""
    if cloud not in ("aws", "azure"):
        die("endpoint operations support aws or azure")
    action = args[1] if len(args) > 1 else ""
    rest = args[2:]
    if cloud == "azure":
        if action == "status":
            if len(rest) != 1:
                raise Usage()
            prepare_with_state(ctx, "azure", rest[0])
            print_json({"pending_endpoint_approvals": azure_endpoint_status(ctx)})
        elif action in ("approve", "reject"):
            if action == "approve" and not (len(rest) == 3 and rest[1] == "--connection-id" and rest[2]):
                die("approve requires: <environment.tfvars> --connection-id <id>")
            if action == "reject" and not (len(rest) == 5 and rest[1] == "--connection-id" and rest[2] and rest[3] == "--confirm" and rest[4] == "reject-azure-endpoint"):
                die("reject requires: <environment.tfvars> --connection-id <id> --confirm reject-azure-endpoint")
            ctx.prepare("azure", rest[0])
            ctx.bind()
            auth.preflight(ctx, "endpoint")
            print_json(decide_azure_endpoint(ctx, action, rest[2]))
        else:
            raise Usage()
        return
    if action == "status":
        if len(rest) != 1:
            raise Usage()
        prepare_with_state(ctx, "aws", rest[0])
        outputs = ctx.terraform_output_json()
        if not isinstance(outputs, dict):
            die("could not read Terraform outputs")
        print_json({
            "pending_endpoint_acceptances": (outputs.get("pending_endpoint_acceptances") or {}).get("value") or [],
            "connectivity": (outputs.get("connectivity") or {}).get("value"),
            "ncc_rules": (outputs.get("ncc_rules") or {}).get("value"),
        })
    elif action == "accept":
        if not (len(rest) == 5 and rest[1] == "--service-id" and rest[3] == "--endpoint-id" and rest[2] and rest[4]):
            die("accept requires: <environment.tfvars> --service-id <id> --endpoint-id <id>")
        ctx.prepare("aws", rest[0])
        auth.preflight(ctx, "endpoint")
        code, _ = clis.aws_cli(ctx, "ec2", "accept-vpc-endpoint-connections", "--service-id", rest[2], "--vpc-endpoint-ids", rest[4], stdout="inherit")
        if code != 0:
            raise_exit(code)
    elif action == "reject":
        if not (len(rest) == 7 and rest[1] == "--service-id" and rest[3] == "--endpoint-id" and rest[5] == "--confirm"
                and rest[6] == "reject-aws-endpoint" and rest[2] and rest[4]):
            die("reject requires: <environment.tfvars> --service-id <id> --endpoint-id <id> --confirm reject-aws-endpoint")
        ctx.prepare("aws", rest[0])
        auth.preflight(ctx, "endpoint")
        code, _ = clis.aws_cli(ctx, "ec2", "reject-vpc-endpoint-connections", "--service-id", rest[2], "--vpc-endpoint-ids", rest[4], stdout="inherit")
        if code != 0:
            raise_exit(code)
    else:
        raise Usage()


def raise_exit(code: int):
    from .common import Exit

    raise Exit(code)


def prepare_with_state(ctx: Context, cloud: str, vars_path: str) -> None:
    ctx.prepare(cloud, vars_path)
    ctx.check_legacy_state()
    ctx.bind()
    if not ctx.state_exists():
        die(f"state not found for deployment '{ctx.id}'")
