#!/usr/bin/env python3
"""Tests for the local web UI: tfvars form editing and the JSON API over a stub ./infra."""
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
# The API tests run the server against a disposable copy of the repository
# whose ./infra is a stub; both modules read these variables at import time.
STUB = tempfile.TemporaryDirectory()
os.environ["STS_INFRA_ROOT"] = STUB.name
os.environ["STS_INFRA_TARGETS_FILE"] = str(Path(STUB.name) / "targets.json")
sys.path.insert(0, str(REPO / "ui"))
sys.path.insert(0, str(REPO / "lib"))

import form  # noqa: E402
import server  # noqa: E402
MANIFEST = json.loads((REPO / "components.json").read_text())


class FormEditing(unittest.TestCase):
    def read_template(self, cloud, name):
        return (REPO / "environments" / "examples" / cloud / f"{name}.tfvars").read_text().splitlines()

    def test_aws_features_connectivity_and_target_are_rewritten_in_place(self):
        lines = self.read_template("aws", "workspace-postgres")
        model = {
            "cloud": "aws", "target": "lab", "region": "us-east-1", "endpoint_approval": "manual",
            "features": {"workspace": True, "unity_catalog": False, "rds_postgres": True, "kafka": True},
            "connectivity": {
                "rds_postgres": {"classic": {"mode": "peering"}, "serverless": {"mode": "private_link"}},
                "kafka": {"classic": {"mode": "none"}, "serverless": {"mode": "private_link"}},
                "rabbitmq": {"classic": {"mode": "peering"}},
            },
        }
        text = "\n".join(form.apply_form(lines, model, MANIFEST))
        self.assertIn('target = "lab"', text)
        self.assertIn('region = "us-east-1"', text)
        self.assertIn('endpoint_approval = "manual"', text)
        self.assertIn("features = {\n  workspace     = true\n  unity_catalog = false\n  rds_postgres  = true\n  kafka         = true\n}", text)
        self.assertIn("  rds_postgres = {\n    classic    = \"peering\"\n    serverless = \"private_link\"\n  }", text)
        self.assertIn("  kafka = {\n    classic    = \"none\"\n    serverless = \"private_link\"\n  }", text)
        self.assertNotIn("rabbitmq", text, "disabled sources get no connectivity block")
        self.assertIn("allow_destructive_demo_cleanup = true", text, "unrelated settings survive")
        self.assertIn("# Scenario:", text)
        self.assertNotIn("00000000-0000-0000-0000-000000000000", text, "a target replaces placeholder account IDs")
        self.assertLess(text.index('endpoint_approval = "manual"'), text.index("features = {"), "new settings join the header")

    def test_azure_classic_path_maps_to_the_peering_option(self):
        lines = self.read_template("azure", "workspace-sql")
        model = {
            "cloud": "azure", "target": None, "region": None, "endpoint_approval": "auto",
            "features": {"workspace": True, "sql_database": True, "test_vm": False},
            "connectivity": {"sql_database": {"classic": {"mode": "peering"}, "serverless": {"mode": "private_link"}}},
        }
        text = "\n".join(form.apply_form(lines, model, MANIFEST))
        self.assertIn("sql_database = {\n  workspace_peering_enabled = true", text)
        self.assertIn("connectivity = {\n  sql_database = {\n    serverless = \"private_link\"\n  }\n}", text)
        self.assertNotIn("target", text)

    def test_removing_every_path_drops_the_connectivity_block(self):
        lines = self.read_template("aws", "workspace-postgres")
        model = {"cloud": "aws", "features": {"workspace": True, "unity_catalog": True, "rds_postgres": False}, "connectivity": {}}
        text = "\n".join(form.apply_form(lines, model, MANIFEST))
        self.assertNotIn("connectivity = {", text)

    def test_form_model_reads_effective_configuration(self):
        config = {
            "features": {"workspace": True, "sql_database": True, "test_vm": False},
            "connectivity": {"sql_database": {"serverless": "private_link"}},
            "sql_database": {"workspace_peering_enabled": True},
            "location": "westus2",
        }
        model = form.form_model("azure", config, MANIFEST)
        self.assertEqual(model["connectivity"]["sql_database"]["classic"], {"mode": "peering", "allowed": ["none", "peering"], "option": "workspace_peering_enabled"})
        self.assertEqual(model["connectivity"]["sql_database"]["serverless"]["mode"], "private_link")
        self.assertEqual(model["region"], "westus2")
        self.assertTrue(model["features"]["sql_database"])

    def test_cloud_is_inferred_from_target_or_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "x.tfvars"
            path.write_text('target = "t"\n')
            self.assertEqual(form.environment_cloud(path, {"t": {"cloud": "azure"}}), "azure")
            path.write_text('subscription_id = "x"\n')
            self.assertEqual(form.environment_cloud(path, {}), "azure")
            path.write_text('features = {\n  workspace = true\n}\n')
            self.assertEqual(form.environment_cloud(path, {}), "aws")


class Api(unittest.TestCase):
    """Runs the server against a copy of the repo whose ./infra is a stub."""

    @classmethod
    def setUpClass(cls):
        root = Path(STUB.name)
        (root / "components.json").write_text((REPO / "components.json").read_text())
        for sub in ("lib", "environments/examples/aws"):
            (root / sub).mkdir(parents=True)
        for src in (REPO / "lib").glob("*.py"):
            (root / "lib" / src.name).write_text(src.read_text())
        (root / "environments" / "examples" / "aws" / "lab.tfvars").write_text(
            (REPO / "environments" / "examples" / "aws" / "workspace-postgres.tfvars").read_text())
        (root / "infra").write_text(
            "#!/usr/bin/env bash\n"
            'printf \'%s\\n\' "$*" >> "$STS_INFRA_TEST_LOG"\n'
            'case "$1 $2" in\n'
            '  "templates --json") echo \'{"version":1,"templates":[{"cloud":"aws","template":"lab","description":"Lab","path":"x"}]}\' ;;\n'
            '  "targets --json") echo \'{"version":1,"targets":{}}\' ;;\n'
            '  "ls --all") echo \'{"version":1,"deployments":[],"hidden":0}\' ;;\n'
            '  "new aws") STS_INFRA_ROOT="$STS_INFRA_ROOT" python3 -I lib/infra_scenario.py "$@" ;;\n'
            '  "plan aws") echo "planned $3"; sleep 0.2; echo "Saved plan summary: create=1"; exit 0 ;;\n'
            '  "apply aws") echo "should not run"; exit 1 ;;\n'
            '  *) echo "stub: $*" >&2; exit 2 ;;\n'
            "esac\n")
        (root / "infra").chmod(0o755)
        cls.log = root / "calls.log"
        os.environ["STS_INFRA_TEST_LOG"] = str(cls.log)
        from http.server import ThreadingHTTPServer
        cls.httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
        cls.url = f"http://127.0.0.1:{cls.httpd.server_address[1]}"
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()
        STUB.cleanup()

    def call(self, path, method="GET", body=None):
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(self.url + path, data=data, method=method, headers={"Content-Type": "application/json"} if data else {})
        try:
            with urllib.request.urlopen(request) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read())

    def test_page_and_catalog(self):
        with urllib.request.urlopen(self.url + "/") as response:
            self.assertIn(b"<title>sts-infra</title>", response.read())
        status, templates = self.call("/api/templates")
        self.assertEqual((status, templates["templates"][0]["template"]), (200, "lab"))
        self.assertEqual(self.call("/api/manifest")[1]["schema_version"], 4)
        self.assertEqual(self.call("/api/nope")[0], 404)

    def test_create_edit_plan_and_guard_apply(self):
        status, created = self.call("/api/environments", "POST", {"cloud": "aws", "name": "my-lab", "template": "lab"})
        self.assertEqual(status, 200, created)
        status, listing = self.call("/api/environments")
        self.assertEqual([env["name"] for env in listing["environments"]], ["my-lab"])
        self.assertEqual(self.call("/api/environments", "POST", {"cloud": "aws", "name": "bad name", "template": "lab"})[0], 400)
        self.assertEqual(self.call("/api/environments", "POST", {"cloud": "gcp", "name": "x", "template": "lab"})[0], 400)

        status, saved = self.call("/api/environments/my-lab", "PUT", {"text": 'aws_account_id = "123456789012"\nfeatures = {\n  workspace = true\n}\n'})
        self.assertEqual(status, 200, saved)
        self.assertIn('aws_account_id = "123456789012"', saved["text"])
        self.assertIsNone(saved["form"], "the stub root has no Terraform, so the form is unavailable and the error is reported")
        self.assertTrue(saved["error"])

        status, run = self.call("/api/environments/my-lab/run", "POST", {"action": "plan"})
        self.assertEqual(status, 200, run)
        self.assertEqual(run["command"], "./infra plan aws environments/local/my-lab.tfvars")
        for _ in range(50):
            status, state = self.call(f"/api/runs/{run['id']}")
            if state["exit_code"] is not None:
                break
            import time
            time.sleep(0.1)
        self.assertEqual(state["exit_code"], 0)
        self.assertIn("Saved plan summary", state["chunk"])

        # Without a saved plan summary the server refuses to apply, and destroy needs its token.
        self.assertEqual(self.call("/api/environments/my-lab/run", "POST", {"action": "apply", "confirm": "apply"})[0], 409)
        self.assertEqual(self.call("/api/environments/my-lab/run", "POST", {"action": "destroy", "confirm": "destroy-aws"})[0], 409)
        self.assertEqual(self.call("/api/environments/my-lab/run", "POST", {"action": "rm -rf"})[0], 400)
        calls = self.log.read_text()
        self.assertNotIn("apply aws", calls)
        self.assertNotIn("destroy aws", calls)


if __name__ == "__main__":
    unittest.main(verbosity=1)
