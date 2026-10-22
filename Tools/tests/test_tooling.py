"""Offline checks of device selection and xcresult manifest export orchestration."""
import contextlib
import io
import json
import pathlib
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2]


def listing():
    return {
        "runtimes": [
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "name": "iOS 27.0", "version": "27.0", "isAvailable": True},
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-1", "name": "iOS 27.1", "version": "27.1", "isAvailable": True},
        ],
        "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [{"name": "iPhone Older", "udid": "old", "isAvailable": True, "state": "Shutdown"}],
            "com.apple.CoreSimulator.SimRuntime.iOS-27-1": [
                {"name": "iPhone Fixture", "udid": "phone", "isAvailable": True, "state": "Booted"},
                {"name": "iPad Fixture", "udid": "pad", "isAvailable": True, "state": "Booted"},
            ],
        },
    }


class ToolingTests(unittest.TestCase):
    def test_selector_uses_newest_runtime_and_both_families(self):
        output = io.StringIO()
        with patch("subprocess.check_output", return_value=json.dumps(listing()).encode()), contextlib.redirect_stdout(output):
            runpy.run_path(str(ROOT / "Tools/select-simulators"), run_name="__main__")
        selected = json.loads(output.getvalue())
        self.assertEqual(selected["iPhone"]["udid"], "phone")
        self.assertEqual(selected["iPad"]["runtime"], "iOS 27.1")

    def test_selector_skips_newer_iphone_only_runtime_without_exporting_paths(self):
        data = listing()
        data["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-27-1"] = [
            {"name": "iPhone Duo", "udid": "duo", "isAvailable": True, "state": "Shutdown"}
        ]
        data["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-27-0"].append(
            {"name": "iPad Fixture", "udid": "tablet", "isAvailable": True, "state": "Shutdown", "dataPath": "private sandbox path"}
        )
        output = io.StringIO()
        with patch("subprocess.check_output", return_value=json.dumps(data).encode()), contextlib.redirect_stdout(output):
            runpy.run_path(str(ROOT / "Tools/select-simulators"), run_name="__main__")
        selected = json.loads(output.getvalue())
        self.assertEqual(selected["iPhone"]["udid"], "old")
        self.assertEqual(selected["iPad"]["runtime"], "iOS 27.0")
        self.assertNotIn("dataPath", selected["iPad"])

    def test_selector_fails_with_iphone_only_runtime(self):
        data = listing()
        for devices in data["devices"].values():
            devices[:] = [device for device in devices if device["name"].startswith("iPhone")]
        with patch("subprocess.check_output", return_value=json.dumps(data).encode()):
            with self.assertRaises(SystemExit):
                runpy.run_path(str(ROOT / "Tools/select-simulators"), run_name="__main__")

    def test_selector_prefers_named_devices_and_logs_fallback(self):
        data = listing()
        devices = data["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-27-1"]
        devices.extend([
            {"name": "iPhone 17 Pro Max", "udid": "seventeen", "isAvailable": True, "state": "Shutdown"},
            {"name": "iPhone 18 Pro Max", "udid": "eighteen", "isAvailable": True, "state": "Shutdown"},
            {"name": "iPad Pro 13-inch (M5)", "udid": "pro", "isAvailable": True, "state": "Shutdown"},
        ])
        for expected in ("eighteen", "seventeen", "phone"):
            output, logs = io.StringIO(), io.StringIO()
            with patch("subprocess.check_output", return_value=json.dumps(data).encode()), contextlib.redirect_stdout(output), contextlib.redirect_stderr(logs):
                runpy.run_path(str(ROOT / "Tools/select-simulators"), run_name="__main__")
            selected = json.loads(output.getvalue())
            self.assertEqual(selected["iPhone"]["udid"], expected)
            self.assertEqual(selected["iPad"]["udid"], "pro")
            self.assertEqual("FALLBACK" in logs.getvalue(), expected == "phone")
            devices[:] = [device for device in devices if device["udid"] != expected]

    def test_selector_fails_without_runtime(self):
        with patch("subprocess.check_output", return_value=b'{"runtimes":[],"devices":{}}'):
            with self.assertRaises(SystemExit):
                runpy.run_path(str(ROOT / "Tools/select-simulators"), run_name="__main__")

    def export(self, omit_last=False):
        # Copy only the executable into an isolated root; no real Artifacts or simulator use.
        (ROOT / ".build").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / ".build") as directory:
            root = pathlib.Path(directory)
            (root / "Tools").mkdir()
            shutil.copyfile(ROOT / "Tools/screenshots", root / "Tools/screenshots")
            calls = []

            def fake_run(command, **kwargs):
                calls.append(command)
                stdout = ""
                if command[:3] == ("xcrun", "simctl", "list"):
                    stdout = json.dumps(listing())
                if command[:4] == ("xcrun", "xcresulttool", "export", "attachments"):
                    destination = pathlib.Path(command[command.index("--output-path") + 1])
                    destination.mkdir()
                    attachments = []
                    for scenario in ("connection-empty", "connection-failed", "console-online"):
                        for appearance in ("light", "dark"):
                            if omit_last and scenario == "console-online" and appearance == "dark":
                                continue
                            name = f"{scenario}__{appearance}.png"
                            (destination / name).write_bytes(b"synthetic export stub")
                            attachments.append({"suggestedHumanReadableName": f"synthetic-fixture__{scenario}__{appearance}", "exportedFileName": name})
                    (destination / "manifest.json").write_text(json.dumps([{"attachments": attachments}]))
                if command[0] == "sips" and "-g" in command:
                    stdout = "pixelWidth: 1000\npixelHeight: 2000\n"
                return subprocess.CompletedProcess(command, 0, stdout=stdout)

            with patch.object(sys, "argv", ["screenshots", "--iphone", "phone", "--ipad", "pad"]), patch("subprocess.run", side_effect=fake_run), contextlib.redirect_stdout(io.StringIO()):
                runpy.run_path(str(root / "Tools/screenshots"), run_name="__main__")
            index = json.loads((root / "Artifacts/Screenshots/index.json").read_text())
            self.assertEqual(len(index), 12)
            self.assertTrue(all(item["label"] == "synthetic fixture" for item in index))
            self.assertEqual(sum(command[0] == "xcodebuild" for command in calls), 2)
            self.assertEqual(sum(command[:3] == ("sips", "-Z", "2000") for command in calls), 12)

    def test_export_requires_and_indexes_complete_matrix(self):
        self.export()

    def test_export_fails_on_missing_scenario(self):
        with self.assertRaises(SystemExit):
            self.export(omit_last=True)


if __name__ == "__main__":
    unittest.main()
