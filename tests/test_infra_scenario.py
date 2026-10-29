#!/usr/bin/env python3
"""Unit tests for lib/infra_scenario.py (templates, new, explain analysis, status)."""
import json
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "lib"))

import infra_scenario as scenario  # noqa: E402

MANIFEST = json.loads((REPO / "components.json").read_text())
ACCOUNT = "11111111-2222-3333-4444-555555555555"


def aws_config(**overrides):
    sources = ("rds_postgres", "rds_sql_server", "aurora_postgres", "rabbitmq", "kafka", "simulated_on_prem")
    config = {
        "region": "us-west-2",
        "aws_account_id": "123456789012",
        "databricks_account_id": ACCOUNT,
        "features": {name: False for name in ("glue_federation", "aurora_proxy", *sources)} | {"workspace": True, "unity_catalog": True},
        "connectivity": {name: {"classic": "none", "serverless": "none"} for name in sources},
        "glue_federation": {"databricks_connectivity_enabled": False},
        "lab_check": {"enabled": True},
        "endpoint_approval": "auto",
    }
    for key, value in overrides.items():
        if isinstance(value, dict) and isinstance(config.get(key), dict):
            config[key] = config[key] | value
        else:
            config[key] = value
    return config


def azure_config(**overrides):
    config = {
        "location": "westus2",
        "subscription_id": "22222222-3333-4444-5555-666666666666",
        "tenant_id": None,
        "databricks_account_id": ACCOUNT,
        "features": {"workspace": True, "test_vm": False, "external_volume_storage": False, "custom_dns": False,
                     "sql_database": True, "sql_server_vm": False},
        "connectivity": {"sql_database": {"serverless": "private_link"}},
        "sql_database": {"workspace_peering_enabled": False},
        "key_vault": {"enabled": True, "databricks_secret_scope_enabled": True},
        "test_vm": {"allowed_ssh_source_cidr": None},
        "lab_check": {"enabled": True},
        "endpoint_approval": "auto",
    }
    for key, value in overrides.items():
        if isinstance(value, dict) and isinstance(config.get(key), dict):
            config[key] = config[key] | value
        else:
            config[key] = value
    return config


def levels(report, level):
    return [item["message"] for item in report["findings"] if item["level"] == level]


class TfvarsParsing(unittest.TestCase):
    def test_top_level_assignments_ignore_comments_and_nested_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "lab.tfvars"
            path.write_text(
                '# Scenario: test\n'
                'target = "lab-aws" # trailing comment\n'
                'region = "us-east-1" // other comment\n'
                'features = {\n  workspace = true\n  target = "nested"\n}\n'
            )
            values = scenario.top_level_assignments(path)
        self.assertEqual(scenario.string_value(values["target"]), "lab-aws")
        self.assertEqual(scenario.string_value(values["region"]), "us-east-1")
        self.assertNotIn("workspace", values)


class Analysis(unittest.TestCase):
    def test_aws_classic_postgres_over_peering(self):
        config = aws_config(features={"rds_postgres": True}, connectivity={"rds_postgres": {"classic": "peering", "serverless": "none"}})
        report = scenario.analyze("aws", config, MANIFEST)
        names = [component["name"] for component in report["components"]]
        self.assertEqual(names[:3], ["workspace", "unity_catalog", "rds_postgres"])
        self.assertIn("lab_check", names)
        self.assertNotIn("ncc", names)
        self.assertEqual(report["checks"], [{"source": "rds_postgres", "compute": "classic", "mode": "peering", "sample_data": True}])
        self.assertEqual(report["stages"], 2)
        self.assertIsNone(report["endpoint_approval"])
        self.assertEqual(levels(report, "error"), [])

    def test_aws_serverless_private_link_derives_ncc(self):
        config = aws_config(features={"rds_sql_server": True}, connectivity={"rds_sql_server": {"classic": "none", "serverless": "private_link"}})
        report = scenario.analyze("aws", config, MANIFEST)
        names = [component["name"] for component in report["components"]]
        self.assertIn("ncc", names)
        self.assertNotIn("classic_private_link", names)
        self.assertEqual(report["endpoint_approval"], "auto")
        self.assertTrue(any("rds_sql_server is expensive" in message for message in levels(report, "warning")))

    def test_connectivity_for_a_disabled_source_is_reported(self):
        config = aws_config(connectivity={"kafka": {"classic": "peering", "serverless": "none"}})
        report = scenario.analyze("aws", config, MANIFEST)
        self.assertTrue(any("connectivity.kafka" in message for message in levels(report, "warning")))

    def test_paths_without_a_workspace_are_errors(self):
        config = aws_config(features={"workspace": False, "unity_catalog": False, "rds_postgres": True},
                            connectivity={"rds_postgres": {"classic": "peering", "serverless": "none"}})
        report = scenario.analyze("aws", config, MANIFEST)
        self.assertTrue(levels(report, "error"))

    def test_placeholders_and_unpinned_accounts(self):
        config = aws_config(aws_account_id=None, databricks_account_id=scenario.PLACEHOLDER_ID)
        report = scenario.analyze("aws", config, MANIFEST)
        self.assertTrue(any("placeholder" in message for message in levels(report, "error")))
        self.assertTrue(any("No AWS account is pinned" in message for message in levels(report, "warning")))

    def test_disconnected_sources_are_informational(self):
        config = aws_config(features={"rds_postgres": True})
        report = scenario.analyze("aws", config, MANIFEST)
        self.assertEqual(report["checks"], [])
        self.assertTrue(any("rds_postgres has no classic or serverless path" in message for message in levels(report, "info")))

    def test_azure_serverless_sql(self):
        report = scenario.analyze("azure", azure_config(), MANIFEST)
        names = [component["name"] for component in report["components"]]
        self.assertIn("ncc", names)
        self.assertIn("key_vault", names)
        self.assertNotIn("vnet_peering", names)
        self.assertEqual(report["checks"], [{"source": "sql_database", "compute": "serverless", "mode": "private_link", "sample_data": True}])
        self.assertEqual(report["stages"], 1)

    def test_azure_classic_path_is_the_peering_option(self):
        config = azure_config(sql_database={"workspace_peering_enabled": True}, connectivity={"sql_database": {"serverless": "none"}})
        report = scenario.analyze("azure", config, MANIFEST)
        self.assertIn("vnet_peering", [component["name"] for component in report["components"]])
        self.assertEqual(report["checks"][0]["mode"], "peering")

    def test_azure_test_vm_needs_a_real_cidr(self):
        config = azure_config(features={"test_vm": True}, test_vm={"allowed_ssh_source_cidr": "203.0.113.10/32"})
        report = scenario.analyze("azure", config, MANIFEST)
        self.assertTrue(any("allowed_ssh_source_cidr" in message for message in levels(report, "error")))


class NextAction(unittest.TestCase):
    def info(self, **overrides):
        base = {"resources": 10, "stage": "complete", "lab_check": True, "state_changed": 100.0,
                "verify": None, "apply_plan": None, "destroy_plan": None}
        return base | overrides

    def test_foundation_stage_needs_the_workspace_login(self):
        command, _ = scenario.next_action("aws", "lab.tfvars", self.info(stage="foundation"))
        self.assertTrue(command.startswith("./infra setup aws"))

    def test_unverified_lab_check(self):
        command, _ = scenario.next_action("aws", "lab.tfvars", self.info())
        self.assertTrue(command.startswith("./infra verify aws"))

    def test_verified_after_the_last_apply_is_done(self):
        verify = {"status": "passed", "checked_at": "now", "checked": 200.0}
        command, reason = scenario.next_action("aws", "lab.tfvars", self.info(verify=verify))
        self.assertIsNone(command)
        self.assertIn("verified", reason)

    def test_stale_saved_plans_are_planned_again(self):
        old = {"path": "x", "created": time.time() - 2 * scenario.FRESH_PLAN_SECONDS}
        fresh = {"path": "x", "created": time.time()}
        self.assertTrue(scenario.next_action("aws", "l.tfvars", self.info(apply_plan=old))[0].startswith("./infra plan"))
        self.assertTrue(scenario.next_action("aws", "l.tfvars", self.info(apply_plan=fresh))[0].startswith("./infra apply"))
        self.assertTrue(scenario.next_action("aws", "l.tfvars", self.info(destroy_plan=old))[0].startswith("./infra destroy-plan"))

    def test_nothing_deployed(self):
        command, _ = scenario.next_action("aws", "lab.tfvars", self.info(resources=0, stage=None))
        self.assertTrue(command.startswith("./infra plan aws"))


class NewEnvironment(unittest.TestCase):
    def test_new_with_target_drops_placeholder_ids(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            examples = root / "environments" / "examples" / "aws"
            examples.mkdir(parents=True)
            (examples / "lab.tfvars").write_text(
                f'# Scenario: Test lab\ndatabricks_account_id = "{scenario.PLACEHOLDER_ID}"\n\nfeatures = {{\n  workspace = true\n}}\n'
            )
            targets = root / "targets.json"
            targets.write_text(json.dumps({"version": 1, "targets": {"lab-aws": {"cloud": "aws", "aws_account_id": "123456789012", "databricks_account_id": ACCOUNT}}}))
            original = scenario.ROOT, scenario.TARGETS_FILE
            scenario.ROOT, scenario.TARGETS_FILE = root, targets
            try:
                self.assertEqual(scenario.main(["new", "aws", "my-lab", "--template", "lab", "--target", "lab-aws"]), 0)
                created = (root / "environments" / "local" / "my-lab.tfvars").read_text()
                with self.assertRaises(SystemExit):
                    scenario.main(["new", "aws", "my-lab", "--template", "lab"])
            finally:
                scenario.ROOT, scenario.TARGETS_FILE = original
        self.assertTrue(created.startswith('# Scenario: Test lab\ntarget = "lab-aws"\n'))
        self.assertNotIn(scenario.PLACEHOLDER_ID, created)

    def test_target_defaults_replace_auto_metastore_and_set_node_type(self):
        target = {"metastore": "shared-uc", "classic_node_type": "m5d.large"}
        lines = ["unity_catalog = {", '  metastore_mode = "auto"', "}"]
        created = "\n".join(scenario.apply_target_defaults(lines, "lab-aws", target))
        self.assertIn('metastore_mode          = "existing"', created)
        self.assertIn('existing_metastore_name = "shared-uc"', created)
        self.assertNotIn('"auto"', created)
        self.assertIn('lab_check = {\n  classic_node_type = "m5d.large"', created)

        # A template that chose create keeps it; an existing lab_check block gains the node type.
        lines = ["unity_catalog = {", '  metastore_mode = "create"', "}", "lab_check = {", "  enabled = true", "}"]
        created = "\n".join(scenario.apply_target_defaults(lines, "lab-aws", target))
        self.assertIn('metastore_mode = "create"', created)
        self.assertNotIn("shared-uc", created)
        self.assertEqual(created.count("lab_check = {"), 1)
        self.assertIn('lab_check = {\n  classic_node_type = "m5d.large"', created)

        # Without target defaults nothing changes.
        lines = ["unity_catalog = {", '  metastore_mode = "auto"', "}"]
        self.assertEqual(scenario.apply_target_defaults(list(lines), "lab-aws", {}), lines)


class Templates(unittest.TestCase):
    def test_every_template_has_a_scenario_description(self):
        for row in scenario.list_templates():
            self.assertTrue(row["description"], f"{row['path']} needs a '# Scenario:' first line")


if __name__ == "__main__":
    unittest.main(verbosity=1)
