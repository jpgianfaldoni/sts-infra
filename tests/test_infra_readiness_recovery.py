#!/usr/bin/env python3
"""Regression tests for cleanup recovery and endpoint/data-plane readiness.

All service responses are fixtures; these tests never access a cloud or a
credential cache. Notebook network checks are exercised without Spark.
"""
import ast
from contextlib import redirect_stdout, redirect_stderr
import io
import ipaddress
import json
from pathlib import Path
import socket
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from sts_infra import auth, endpoints, plans, recovery, verify
from sts_infra.common import Exit
import infra_scenario

SUBSCRIPTION = "00000000-0000-0000-0000-000000000000"
WORKSPACE_ID = f"/subscriptions/{SUBSCRIPTION}/resourceGroups/lab/providers/Microsoft.Databricks/workspaces/lab"
VAULT_ID = f"/subscriptions/{SUBSCRIPTION}/resourceGroups/lab/providers/Microsoft.KeyVault/vaults/lab"
SECRET_URI = "https://lab.vault.azure.net/secrets/db-password"
RULE_ADDRESS = "module.ncc[0].databricks_mws_ncc_private_endpoint_rule.sql_server_vm[0]"


def resource(kind, name, attributes, module="", provider=""):
    return {"mode": "managed", "type": kind, "name": name, "module": module, "provider": provider,
            "instances": [{"attributes": attributes}]}


class EndpointTests(unittest.TestCase):
    def setUp(self):
        self.expected = {"db": {"rule_id": "r1"}}
        self.live = {"rule_id": "r1", "connection_state": "ESTABLISHED", "deactivated": False}

    def test_established_tombstone_is_not_ready(self):
        self.live["deactivated"] = True
        self.assertEqual(endpoints.rule_problems(self.expected, [self.live])[0]["state"], "DEACTIVATED")

    def test_missing_rule_is_not_ready_even_if_other_rules_are_ready(self):
        expected = {**self.expected, "other": {"rule_id": "r2"}}
        self.assertEqual(endpoints.rule_problems(expected, [self.live]), [{"source": "other", "rule_id": "r2", "state": "MISSING"}])

    def test_active_rule_is_ready(self):
        self.assertEqual(endpoints.rule_problems(self.expected, {"items": [self.live]}), [])

    def test_empty_or_incomplete_response_is_not_success(self):
        self.assertFalse(endpoints.valid_rule_list({}))
        self.assertFalse(endpoints.valid_rule_list({"items": [], "next_page_token": "next"}))
        self.assertFalse(endpoints.valid_rule_list([None]))
        self.assertFalse(endpoints.valid_rule_list([{"rule_id": "r1", "deactivated": "false"}]))
        self.assertFalse(endpoints.valid_rule_list([self.live, self.live]))
        self.assertEqual(endpoints.rule_problems(self.expected, [])[0]["state"], "MISSING")

    def test_wait_checks_once_with_zero_budget_and_retries_pending(self):
        ctx = SimpleNamespace()
        outputs = {"serverless_connectivity": {"value": {"network_connectivity_config_id": "ncc", "rules": self.expected}}}
        lab = {"checks": {"db_serverless": {"source": "db", "compute": "serverless"}}}
        with patch.object(verify.clis, "databricks_account_cli", return_value=(0, '{"items":[]}')):
            self.assertEqual(verify.wait_for_serverless_rules(ctx, outputs, lab, 0)[0]["state"], "MISSING")
        with patch.object(verify.clis, "databricks_account_cli", side_effect=[
            (0, '{"items":[{"rule_id":"r1","connection_state":"PENDING"}]}'),
            (0, json.dumps([self.live])),
        ]) as api, patch.object(verify.time, "sleep"):
            self.assertEqual(verify.wait_for_serverless_rules(ctx, outputs, lab, 1), [])
            self.assertEqual(api.call_count, 2)

    def test_api_failure_and_missing_ncc_fail_closed(self):
        lab = {"checks": {"db_serverless": {"source": "db", "compute": "serverless"}}}
        self.assertEqual(verify.wait_for_serverless_rules(None, {}, lab, 0)[0]["state"], "NO_NCC")
        outputs = {"serverless_connectivity": {"value": {"network_connectivity_config_id": "ncc", "rules": self.expected}}}
        with patch.object(verify.clis, "databricks_account_cli", return_value=(1, "denied")):
            self.assertEqual(verify.wait_for_serverless_rules(None, outputs, lab, 0)[0]["state"], "API_UNREADABLE")


class NotebookNetworkTests(unittest.TestCase):
    def setUp(self):
        path = Path(__file__).resolve().parents[1] / "modules/shared/lab-check/notebooks/lab_check.py"
        tree = ast.parse(path.read_text())
        function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "check_network")
        self.clock = SimpleNamespace(now=0)

        def sleep(seconds):
            self.clock.now += seconds

        self.ns = {"socket": MagicMock(), "ipaddress": ipaddress,
                   "time": SimpleNamespace(monotonic=lambda: self.clock.now, sleep=sleep),
                   "NETWORK_WAIT_SECONDS": 30, "TCP_TIMEOUT_SECONDS": 15,
                   "host": "db.lab", "port": 1433, "result": {}, "stage": "dns", "path_hint": lambda: "check path"}

        def enter(stage):
            self.ns["stage"] = stage

        def fail(stage, message, hint):
            raise RuntimeError(f"{stage}: {message}")

        self.ns.update(enter=enter, fail=fail)
        exec(compile(ast.Module(body=[function], type_ignores=[]), str(path), "exec"), self.ns)

    def answers(self, ip="10.0.0.4"):
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (ip, 1433))]

    def test_dns_propagates_before_tcp_is_attempted(self):
        self.ns["socket"].getaddrinfo.side_effect = [socket.gaierror("pending"), self.answers()]
        self.ns["check_network"]()
        self.assertEqual(self.ns["result"]["network_attempts"], 2)
        self.ns["socket"].create_connection.assert_called_once_with(("10.0.0.4", 1433), timeout=15)

    def test_public_dns_fallback_never_receives_a_connection(self):
        self.ns["socket"].getaddrinfo.return_value = self.answers("8.8.8.8")
        with self.assertRaisesRegex(RuntimeError, "dns:.*non-private"):
            self.ns["check_network"]()
        self.ns["socket"].create_connection.assert_not_called()
        self.assertEqual(self.clock.now, 30)

    def test_ipv4_mapped_private_address_works(self):
        self.ns["socket"].getaddrinfo.return_value = self.answers("::ffff:172.22.98.16")
        self.ns["check_network"]()
        self.assertEqual(self.ns["result"]["network_attempts"], 1)

    def test_tcp_timeout_is_reported_after_bounded_wait(self):
        self.ns["socket"].getaddrinfo.return_value = self.answers()
        self.ns["socket"].create_connection.side_effect = OSError("timeout")
        with self.assertRaisesRegex(RuntimeError, "tcp:.*timeout"):
            self.ns["check_network"]()
        self.assertEqual(self.clock.now, 30)

    def test_classic_can_try_other_private_addresses_without_retry_wait(self):
        self.ns["NETWORK_WAIT_SECONDS"] = 0
        self.ns["socket"].getaddrinfo.return_value = self.answers("10.0.0.4") + self.answers("10.0.0.5")
        connection = MagicMock()
        self.ns["socket"].create_connection.side_effect = [OSError("refused"), connection]
        self.ns["check_network"]()
        self.assertEqual(self.ns["socket"].create_connection.call_count, 2)
        self.assertEqual(self.clock.now, 0)


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.state = root / "terraform.tfstate"
        self.vars = root / "lab.tfvars"
        self.vars.write_text('target = "test"\n')
        self.data = {"version": 4, "serial": 1, "outputs": {}, "resources": []}
        self.ctx = SimpleNamespace(
            cloud="azure", id="lab", vars=str(self.vars), display_vars="lab.tfvars", state=str(self.state), artifacts=str(root),
            dir=str(root), context_sha="identity-1", tf_args=[], plan_stage="complete", plan_replace=[],
            az_subscription=SUBSCRIPTION, command_line="./infra recover-plan azure lab.tfvars",
            prepare=MagicMock(), check_legacy_state=MagicMock(), bind=MagicMock(), acquire_lock=MagicMock(),
            state_exists=lambda: self.state.exists(), state_json=lambda: json.loads(self.state.read_text()),
            endpoint_approval_mode=lambda: "auto", tfvar=lambda *args: "", call=MagicMock(), terraform=MagicMock(return_value=(0, "")),
        )
        self.save_state()
        for target in (patch.object(auth, "preflight"),
                       patch.object(plans, "terraform_init"), patch.object(plans, "configuration_sha256", return_value="config-1")):
            target.start()
            self.addCleanup(target.stop)

    def save_state(self):
        self.state.write_text(json.dumps(self.data))

    def add_rule(self):
        entry = resource("databricks_mws_ncc_private_endpoint_rule", "sql_server_vm",
                         {"network_connectivity_config_id": "ncc", "rule_id": "rule"}, "module.ncc[0]")
        entry["instances"][0]["index_key"] = 0
        self.data["resources"].append(entry)
        self.save_state()

    def tombstone(self):
        return patch.object(recovery.clis, "databricks_account_cli", return_value=(0, json.dumps({
            "items": [{"rule_id": "rule", "connection_state": "ESTABLISHED", "deactivated": True}],
        })))

    def test_recovery_plan_does_not_mutate_state_or_cloud(self):
        self.add_rule()
        before = self.state.read_bytes()
        with self.tombstone():
            recovery.recover_plan(self.ctx, str(self.vars))
        self.assertEqual(before, self.state.read_bytes())
        self.ctx.terraform.assert_not_called()
        report = json.loads(Path(recovery.repair_path(self.ctx)).read_text())
        self.assertEqual(report["forget"][0]["address"], RULE_ADDRESS)
        self.assertTrue(Path(recovery.repair_path(self.ctx) + ".metadata").exists())

    def test_reviewed_repairs_are_rechecked_and_applied_once(self):
        self.add_rule()
        with self.tombstone():
            recovery.recover_plan(self.ctx, str(self.vars))
            self.assertEqual(recovery.apply_repairs(self.ctx, "azure", str(self.vars)), 0)
        self.ctx.terraform.assert_called_once_with("state", "rm", "--", RULE_ADDRESS, stdout="null", stderr="null")
        self.assertFalse(recovery.pending(self.ctx))
        self.assertTrue(Path(recovery.repair_path(self.ctx) + ".state.backup").exists())
        with self.assertRaisesRegex(Exit, "already applied"):
            recovery.apply_repairs(self.ctx, "azure", str(self.vars))

    def test_changed_state_identity_and_tampered_plan_are_rejected(self):
        for change, pattern in (("state", "state changed"), ("identity", "identity"), ("plan", "saved plan changed")):
            with self.subTest(change=change):
                self.ctx.context_sha = "identity-1"
                self.add_rule()
                with self.tombstone():
                    recovery.recover_plan(self.ctx, str(self.vars))
                    if change == "state":
                        self.state.write_text(self.state.read_text() + "\n")
                    elif change == "identity":
                        self.ctx.context_sha = "identity-2"
                    else:
                        path = Path(recovery.repair_path(self.ctx))
                        path.write_text(path.read_text() + "\n")
                    with self.assertRaisesRegex(Exit, pattern):
                        recovery.apply_repairs(self.ctx, "azure", str(self.vars))
                self.ctx.terraform.assert_not_called()

    def test_live_rule_reactivation_prevents_forgetting(self):
        self.add_rule()
        with self.tombstone():
            recovery.recover_plan(self.ctx, str(self.vars))
        with patch.object(recovery.clis, "databricks_account_cli", return_value=(0, '[{"rule_id":"rule","connection_state":"ESTABLISHED"}]')):
            with self.assertRaisesRegex(Exit, "evidence changed"):
                recovery.apply_repairs(self.ctx, "azure", str(self.vars))
        self.ctx.terraform.assert_not_called()

    def test_unreadable_ncc_and_azure_forbidden_do_not_prove_deletion(self):
        self.add_rule()
        with patch.object(recovery.clis, "databricks_account_cli", return_value=(1, "forbidden")):
            with self.assertRaisesRegex(Exit, "could not inspect NCC"):
                recovery.inspect(self.ctx)
        self.ctx.call.return_value = (1, "ERROR: (AuthorizationFailed) denied")
        with self.assertRaisesRegex(Exit, "not proof of deletion"):
            recovery.azure_resource_exists(self.ctx, WORKSPACE_ID)
        with self.assertRaisesRegex(Exit, "outside"):
            recovery.azure_resource_exists(self.ctx, "/subscriptions/other/resourceGroups/lab")

    def test_missing_workspace_forgets_only_its_workspace_provider_resources(self):
        self.data["resources"] = [
            resource("azurerm_databricks_workspace", "this", {"id": WORKSPACE_ID}, "module.workspace[0]"),
            resource("databricks_job", "this", {"id": "55"}, "module.lab_check[0]",
                     'provider["registry.terraform.io/databricks/databricks"].workspace'),
            resource("databricks_mws_ncc_binding", "this", {"id": "binding"}, "module.ncc[0]",
                     'provider["registry.terraform.io/databricks/databricks"].account'),
        ]
        self.save_state()
        self.ctx.call.return_value = (1, "ERROR: (ResourceNotFound) missing")
        report = recovery.inspect(self.ctx)
        self.assertEqual([item["address"] for item in report["forget"]], ["module.lab_check[0].databricks_job.this"])
        self.assertEqual(report["deleted"][0]["id"], WORKSPACE_ID)

    def vault(self, secret_in_state=False):
        self.data["resources"] = [resource("azurerm_key_vault", "this", {"id": VAULT_ID}, "module.key_vault[0]")]
        self.data["outputs"]["key_vault"] = {"value": {"name": "lab", "id": VAULT_ID, "uri": "https://lab.vault.azure.net/",
                                                       "secret_names": ["db-password"]}}
        if secret_in_state:
            self.data["resources"].append(resource("azurerm_key_vault_secret", "this", {"name": "db-password", "key_vault_id": VAULT_ID}))
        self.save_state()

    def test_secret_recovery_uses_metadata_only_and_imports_versioned_id(self):
        self.vault()
        self.ctx.call.side_effect = [
            (0, json.dumps(VAULT_ID)), (0, json.dumps([{"name": "db-password", "id": SECRET_URI},
                                                     {"name": "unrelated", "id": "https://other.vault.azure.net/secrets/x"}])),
            (0, json.dumps(SECRET_URI + "/version1")),
        ]
        report = recovery.inspect(self.ctx)
        self.assertEqual(report["secret_imports"], {"db-password": SECRET_URI + "/version1"})
        commands = [call.args[0] for call in self.ctx.call.call_args_list]
        self.assertFalse(any("show" in cmd and "secret" in cmd for cmd in commands))
        self.assertEqual(commands[-1][3], "list-versions")

    def test_deleted_vault_is_restored_before_inspecting_secrets(self):
        self.vault()
        self.ctx.call.return_value = (1, "ERROR: (ResourceGroupNotFound) missing")
        with patch.object(plans, "save_prepared_plan") as save:
            recovery.recover_plan(self.ctx, str(self.vars))
        save.assert_called_once_with(self.ctx, "apply", targets=["module.key_vault[0].azurerm_key_vault.this"], recovery=True)
        self.assertEqual(self.ctx.call.call_count, 1)

    def test_existing_managed_secret_is_not_reimported(self):
        self.vault(secret_in_state=True)
        self.ctx.call.return_value = (0, json.dumps(VAULT_ID))
        self.assertEqual(recovery.inspect(self.ctx)["secret_imports"], {})
        self.ctx.call.assert_called_once()

    def test_import_plan_receives_metadata_ids_through_terraform_variables(self):
        self.vault()
        self.ctx.call.side_effect = [(0, json.dumps(VAULT_ID)),
                                     (0, json.dumps([{"name": "db-password", "id": SECRET_URI}])),
                                     (0, json.dumps(SECRET_URI + "/version1"))]
        with patch.object(plans, "save_prepared_plan") as save:
            recovery.recover_plan(self.ctx, str(self.vars))
        self.assertEqual(json.loads(self.ctx.tf_args[-1].split("=", 2)[2]), {"db-password": SECRET_URI + "/version1"})
        save.assert_called_once_with(self.ctx, "apply", targets=[], recovery=True)

    def test_wrong_vault_secret_metadata_is_refused(self):
        self.vault()
        self.ctx.call.side_effect = [(0, json.dumps(VAULT_ID)),
                                     (0, json.dumps([{"name": "db-password", "id": "https://other.vault.azure.net/secrets/db-password"}]))]
        with self.assertRaisesRegex(Exit, "does not match"):
            recovery.recover_plan(self.ctx, str(self.vars))
        self.ctx.terraform.assert_not_called()

    def test_missing_workspace_parent_is_restored_before_workspace_objects(self):
        self.data["resources"] = [resource("azurerm_databricks_workspace", "this", {"id": WORKSPACE_ID}, "module.workspace[0]")]
        self.save_state()
        self.ctx.call.return_value = (1, "ERROR: (ResourceNotFound) missing")
        with patch.object(plans, "save_prepared_plan") as save:
            recovery.recover_plan(self.ctx, str(self.vars))
        save.assert_called_once_with(self.ctx, "apply", targets=["module.workspace[0].azurerm_databricks_workspace.this"], recovery=True)

    def test_status_resumes_failed_repairs_with_a_new_recovery_plan(self):
        self.add_rule()
        self.ctx.terraform.return_value = (1, "failed")
        with self.tombstone():
            recovery.recover_plan(self.ctx, str(self.vars))
            with self.assertRaises(Exit):
                recovery.apply_repairs(self.ctx, "azure", str(self.vars))
        pending = infra_scenario.recovery_plan(Path(self.ctx.artifacts))
        command, _reason = infra_scenario.next_action("azure", str(self.vars), {"destroy_plan": None, "apply_plan": pending})
        self.assertTrue(command.startswith("./infra recover-plan azure"))

    def test_failed_state_repair_cannot_be_reused(self):
        self.add_rule()
        self.ctx.terraform.return_value = (1, "failed")
        with self.tombstone():
            recovery.recover_plan(self.ctx, str(self.vars))
            with self.assertRaisesRegex(Exit, "invalidated"):
                recovery.apply_repairs(self.ctx, "azure", str(self.vars))
            with self.assertRaisesRegex(Exit, "interrupted or failed"):
                recovery.apply_repairs(self.ctx, "azure", str(self.vars))


if __name__ == "__main__":
    # Test diagnostics are useful on failure without cluttering validation.
    with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
        suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
        result = unittest.TextTestRunner(stream=sys.__stderr__, verbosity=1).run(suite)
    sys.exit(not result.wasSuccessful())
