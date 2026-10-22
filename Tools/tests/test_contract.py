"""Offline contract gate regressions; no network or upstream mutations."""
import contextlib
import io
import json
import pathlib
import runpy
import shutil
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
MODULE = runpy.run_path(str(ROOT / "Tools/check-contract"))


class ContractTests(unittest.TestCase):
    def sandbox(self):
        # A fresh CI checkout has no .build directory yet.
        (ROOT / ".build").mkdir(exist_ok=True)
        temporary = tempfile.TemporaryDirectory(dir=ROOT / ".build")
        self.addCleanup(temporary.cleanup)
        root = pathlib.Path(temporary.name)
        for relative in ["Contracts", "Packages/MonoAgentKit/Tests/MonoAgentKitTests", "Packages/MonoAgentKit/Sources/MonoAgentKit"]:
            shutil.copytree(ROOT / relative, root / relative)
        return root

    def test_generated_ledger_is_current(self):
        generator = runpy.run_path(str(ROOT / "Tools/generate-routes"))
        expected = generator["outputs"]()["Contracts/routes-ledger.json"]
        self.assertEqual((ROOT / "Contracts/routes-ledger.json").read_text(), expected)

    def test_pin_and_coverage(self):
        with contextlib.redirect_stdout(io.StringIO()):
            MODULE["check"]()

    def test_tampered_resource_fails_hash(self):
        root = self.sandbox()
        lock = json.loads((root / "Contracts/console-api.lock.json").read_text())
        path = root / lock["artifacts"][0]["resource"]
        path.write_bytes(path.read_bytes() + b"\n")
        with self.assertRaisesRegex(AssertionError, "SHA-256 mismatch"):
            MODULE["check"](root)

    def test_uncovered_route_fails(self):
        root = self.sandbox()
        path = root / "Contracts/routes-ledger.json"
        ledger = json.loads(path.read_text())
        ledger["routes"].pop()
        path.write_text(json.dumps(ledger))
        with self.assertRaisesRegex(AssertionError, "Route coverage drift"):
            MODULE["check"](root)

    def test_origin_policy_drift_fails(self):
        root = self.sandbox()
        path = root / "Contracts/routes-ledger.json"
        ledger = json.loads(path.read_text())
        ledger["routes"][0]["originPolicy"] = "exact"
        path.write_text(json.dumps(ledger))
        with self.assertRaisesRegex(AssertionError, "Route policy drift"):
            MODULE["check"](root)

    def test_definition_library_is_not_a_fixture_root_schema(self):
        validate = MODULE["validate"]
        definitions = {"Example": {"type": "object", "required": ["requiredValue"], "properties": {"requiredValue": {"type": "string"}}, "additionalProperties": False}}
        validate({"requiredValue": "fictional"}, {"$ref": "#/definitions/Example"}, definitions)
        with self.assertRaisesRegex(ValueError, "missing required"):
            validate({}, definitions["Example"], definitions)
        with self.assertRaisesRegex(ValueError, "expected"):
            validate({"requiredValue": 42}, definitions["Example"], definitions)


if __name__ == "__main__":
    unittest.main()
