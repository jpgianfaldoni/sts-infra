"""./infra command line: argument handling and dispatch.

Exit codes: 0 success, 1 error, 2 usage, 10 browser login required, 11 identity
or account mismatch (or no pinned account), 12 missing or outdated tool, 13 a
lab check failed (verify).
"""
from __future__ import annotations

import json
import sys

from . import auth, authconfig, endpoints, operations, plans, setup, verify, vm_setup
from .common import ADDRESS_PATTERN, EXIT_USAGE, ROOT, Exit, Usage, die, err, out
from .context import Context, Interrupted, cloud_root, scenario

USAGE = """Usage:
  ./infra list
  ./infra templates [<aws|azure>] [--json]
  ./infra new <aws|azure> <name> --template <template> [--target <target>]
  ./infra explain <aws|azure> <environment.tfvars> [--json]
  ./infra ls [--json]
  ./infra status <aws|azure> <environment.tfvars> [--json]
  ./infra targets [--json]
  ./infra targets add <name> --cloud <aws|azure> [target options]
  ./infra targets remove <name>
  ./infra setup <aws|azure> <environment.tfvars> [setup options]
  ./infra doctor <aws|azure> [<environment.tfvars>] [--json] [--wait <seconds>]
  ./infra validate <aws|azure>
  ./infra plan <aws|azure> <environment.tfvars> [--replace <resource address>]...
  ./infra apply <aws|azure> <environment.tfvars>
  ./infra verify <aws|azure> <environment.tfvars> [--json] [--endpoint-wait <seconds>]
  ./infra seed-access-plan azure <environment.tfvars> [--operator-ip <ipv4>]
  ./infra seed-access-apply azure <environment.tfvars>
  ./infra seed azure <environment.tfvars> [--source <directory>] [--destination-path <path>]
  ./infra output <aws|azure> <environment.tfvars> [--json]
  ./infra destroy-plan <aws|azure> <environment.tfvars>
  ./infra destroy <aws|azure> <environment.tfvars> --confirm destroy-<cloud>
  ./infra state-migrate <aws|azure> <environment.tfvars> --confirm migrate-<cloud>-<deployment-id>
  ./infra state-forget <aws|azure> <environment.tfvars> <resource address> --confirm forget-<cloud>-<deployment-id>
  ./infra vm-setup-status azure <environment.tfvars> [--json]
  ./infra endpoints aws status <environment.tfvars>
  ./infra endpoints aws accept <environment.tfvars> --service-id vpce-svc-... --endpoint-id vpce-...
  ./infra endpoints aws reject <environment.tfvars> --service-id vpce-svc-... --endpoint-id vpce-... --confirm reject-aws-endpoint
  ./infra endpoints azure status <environment.tfvars>
  ./infra endpoints azure approve <environment.tfvars> --connection-id <id>
  ./infra endpoints azure reject <environment.tfvars> --connection-id <id> --confirm reject-azure-endpoint

Setup options (setup asks no questions with --yes or when stdin is not a terminal):
  --yes                        accept the detected defaults without prompting
  --aws-profile <name>         AWS CLI profile to use or create
  --aws-account-id <id>        account for a new SSO profile (default: aws_account_id in tfvars)
  --sso-start-url <url>        IAM Identity Center start URL for a new SSO profile
  --sso-region <region>        IAM Identity Center region for a new SSO profile
  --sso-role-name <role>       permission-set role for a new SSO profile
  --sso-session <name>         shared SSO session for new profiles (default: sts-infra)
  --databricks-profile <name>  Databricks account profile to use or create
  --no-databricks-profile      Azure only: use the Azure CLI identity for account APIs
  --workspace-profile <name>   Databricks workspace profile to use or create
  --skip-workspace             do not set up workspace authentication
  --no-workspace-profile       Azure only: forget the saved workspace profile and use the Azure CLI identity
  --workspace-login            log in to the workspace even when no check requires it yet
  --tenant <id>                Azure only: Entra tenant for az login
  --device-code                use device-code login for AWS and Azure
  --force-login                log in again even when the AWS or Azure session is valid

Target options (non-secret identifiers; saved in the local targets file):
  --description <text>
  AWS:   --aws-account-id <id> --databricks-account-id <uuid> [--region <region>]
         [--sso-start-url <url> --sso-region <region> --sso-role-name <role>]
         [--aws-profile <name>] [--databricks-profile <name>]
         [--metastore <name>]   Unity Catalog metastore new environments use instead of auto
  Azure: --subscription-id <uuid> [--tenant-id <uuid>] [--databricks-account-id <uuid>]
         [--location <location>] [--databricks-profile <name>]
  Both:  [--classic-node-type <type>]   node type for the lab check cluster in new environments

Authentication overrides for local operators:
  AWS_PROFILE
  DATABRICKS_ACCOUNT_PROFILE
  DATABRICKS_WORKSPACE_PROFILE
  STS_INFRA_AUTH_CONFIG (defaults to ~/.config/sts-infra/auth.json)
  STS_INFRA_TARGETS (defaults to targets.json next to the auth config)
  STS_INFRA_ALLOW_UNPINNED_ACCOUNT=1 (automation only: allow AWS environments without a pinned account)

Automation can omit profiles and use the standard AWS, Azure, and Databricks
provider environment variables. Set INFRA_DEPLOYMENT_ID to supply a stable
application deployment ID; otherwise the tfvars filename is used.

Exit codes: 0 success, 1 error, 2 usage, 10 browser login required,
11 identity or account mismatch (or no pinned account), 12 missing or outdated
tool, 13 a lab check failed (verify).
"""


def require(condition: bool) -> None:
    if not condition:
        raise Usage()


def plan_command(ctx: Context, args: list) -> None:
    require(len(args) >= 2)
    cloud, vars_path, rest = args[0], args[1], args[2:]
    while rest:
        require(rest[0] == "--replace" and len(rest) >= 2)
        if not ADDRESS_PATTERN.fullmatch(rest[1]):
            die(f"invalid resource address for --replace: {rest[1]}")
        ctx.plan_replace.append(rest[1])
        rest = rest[2:]
    plans.create_plan(ctx, cloud, vars_path, "apply")


def dispatch(ctx: Context, argv: list) -> int:
    command, args = (argv[0] if argv else ""), argv[1:]
    if command == "list":
        require(not args)
        with open(f"{ROOT}/components.json") as handle:
            out(json.dumps(json.load(handle), indent=2, ensure_ascii=False))
        return 0
    if command in ("templates", "new", "explain", "ls", "status", "targets"):
        return scenario.main(argv) or 0
    if command == "verify":
        return verify.verify_command(ctx, args)
    if command == "setup":
        require(len(args) >= 2)
        cloud_root(args[0])
        setup.setup_command(ctx, args[0], args[1], args[2:])
        return 0
    if command in ("doctor", "auth"):
        require(len(args) >= 1)
        if command == "auth":
            err("WARNING: './infra auth' is deprecated; use './infra doctor'.")
        return auth.doctor_command(ctx, args[0], args[1:])
    if command == "validate":
        require(len(args) == 1)
        import subprocess

        return subprocess.call([f"{ROOT}/scripts/validate.sh", args[0]])
    if command == "plan":
        plan_command(ctx, args)
        return 0
    if command == "apply":
        require(len(args) == 2)
        return plans.apply_plan(ctx, args[0], args[1], "apply")
    if command == "seed-access-plan":
        if not args or args[0] != "azure":
            die("seed access currently supports azure only")
        if len(args) == 2:
            operations.create_seed_access_plan(ctx, args[1])
        elif len(args) == 4 and args[2] == "--operator-ip" and args[3]:
            operations.create_seed_access_plan(ctx, args[1], args[3])
        else:
            raise Usage()
        return 0
    if command == "seed-access-apply":
        if not (len(args) == 2 and args[0] == "azure"):
            die("seed-access-apply requires: azure <environment.tfvars>")
        return operations.apply_seed_access_plan(ctx, args[1])
    if command == "seed":
        return operations.seed_command(ctx, args)
    if command == "output":
        if len(args) == 2:
            return operations.show_outputs(ctx, args[0], args[1], False)
        require(len(args) == 3 and args[2] == "--json")
        return operations.show_outputs(ctx, args[0], args[1], True)
    if command == "destroy-plan":
        require(len(args) == 2)
        plans.create_plan(ctx, args[0], args[1], "destroy")
        return 0
    if command == "destroy":
        if not (len(args) == 4 and args[2] == "--confirm" and args[3] == f"destroy-{args[0]}"):
            die("destroy requires: --confirm destroy-<cloud>")
        return plans.apply_plan(ctx, args[0], args[1], "destroy")
    if command == "state-migrate":
        if not (len(args) == 4 and args[2] == "--confirm"):
            die("state migration requires an environment-specific confirmation; see ./infra usage")
        operations.migrate_state(ctx, args[0], args[1], args[3])
        return 0
    if command == "state-forget":
        if not (len(args) == 5 and args[3] == "--confirm"):
            die("state-forget requires: <cloud> <environment.tfvars> <resource address> --confirm forget-<cloud>-<deployment-id>")
        operations.forget_state(ctx, args[0], args[1], args[2], args[4])
        return 0
    if command == "vm-setup-status":
        return vm_setup.vm_setup_command(ctx, args)
    if command == "endpoints":
        endpoints.endpoints_command(ctx, args)
        return 0
    raise Usage()


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    ctx = Context("./infra " + " ".join(argv))
    scenario.ROOT = __import__("pathlib").Path(ROOT)
    scenario.TARGETS_FILE = __import__("pathlib").Path(authconfig.targets_path())
    code = 0
    try:
        code = dispatch(ctx, argv)
    except Usage:
        sys.stdout.write(USAGE)
        code = EXIT_USAGE
    except Exit as stop:
        if stop.message:
            err(f"ERROR: {stop.message}")
        code = stop.code
    except (KeyboardInterrupt, Interrupted) as stop:
        code = getattr(stop, "code", 130)
        if ctx.active_plan:
            try:
                plans.record_failed_plan(ctx, ctx.active_plan, ctx.active_metadata, ctx.active_action)
            except Exception:  # noqa: BLE001 - still release the lock and exit
                pass
    except BrokenPipeError:
        code = 1
    finally:
        try:
            ctx.release_lock()
        except OSError:
            pass
    sys.stdout.flush()
    return code
