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
MATRIX = json.loads((ROOT / "Tools/screenshot-matrix.json").read_text())["entries"]


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

    def export(self, omit_last=False, extra=None, fail_family=None):
        # Copy only the executable into an isolated root; no real Artifacts or simulator use.
        (ROOT / ".build").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / ".build") as directory:
            root = pathlib.Path(directory)
            (root / "Tools").mkdir()
            shutil.copyfile(ROOT / "Tools/screenshots", root / "Tools/screenshots")
            shutil.copyfile(ROOT / "Tools/screenshot-matrix.json", root / "Tools/screenshot-matrix.json")
            calls = []

            def fake_run(command, **kwargs):
                calls.append(command)
                stdout = ""
                if command[0] == "xcodebuild":
                    bundle = pathlib.Path(command[command.index("-resultBundlePath") + 1])
                    bundle.mkdir(parents=True)
                    self.assertIn("-collect-test-diagnostics", command)
                    self.assertEqual(command[command.index("-collect-test-diagnostics") + 1], "never")
                    if fail_family and bundle.name == f"{fail_family}.xcresult":
                        raise subprocess.CalledProcessError(65, command)
                if command[:3] == ("xcrun", "simctl", "list"):
                    stdout = json.dumps(listing())
                if command[:4] == ("xcrun", "xcresulttool", "export", "attachments"):
                    destination = pathlib.Path(command[command.index("--output-path") + 1])
                    destination.mkdir()
                    attachments = []
                    entries = MATRIX[:-1] if omit_last else MATRIX
                    for number, entry in enumerate(entries + ([extra] if extra else [])):
                        suffix = f"__{entry['variant']}" if entry.get("variant") else ""
                        label = f"synthetic-fixture__{entry['scenario']}__{entry['appearance']}{suffix}"
                        name = f"{number}.png"
                        (destination / name).write_bytes(b"synthetic export stub")
                        # xcresulttool appends an index and UUID to the attachment name.
                        attachments.append({"suggestedHumanReadableName": f"{label}_0_0F0E0D0C-0000-4000-8000-00000000000{number % 10}.png", "exportedFileName": name})
                    (destination / "manifest.json").write_text(json.dumps([{"attachments": attachments}]))
                if command[0] == "sips" and "-g" in command:
                    stdout = "pixelWidth: 1000\npixelHeight: 2000\n"
                return subprocess.CompletedProcess(command, 0, stdout=stdout)

            with patch.object(sys, "argv", ["screenshots", "--iphone", "phone", "--ipad", "pad"]), patch("subprocess.run", side_effect=fake_run), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                try:
                    runpy.run_path(str(root / "Tools/screenshots"), run_name="__main__")
                finally:
                    self.calls = calls
                    index_path = root / "Artifacts/Screenshots/index.json"
                    self.partial_index = json.loads(index_path.read_text()) if index_path.exists() else None
            index = json.loads((root / "Artifacts/Screenshots/index.json").read_text())
            self.assertEqual(len(index), 2 * len(MATRIX))
            self.assertTrue(all(item["label"] == "synthetic fixture" for item in index))
            self.assertEqual(sum(command[0] == "xcodebuild" for command in calls), 2)
            self.assertEqual(sum(command[:3] == ("sips", "-Z", "2000") for command in calls), 2 * len(MATRIX))
            files = {item["file"] for item in index}
            self.assertIn("iPhone__connection-failed__light__ax3.png", files)
            self.assertIn("iPad__design-catalog-reduce-transparency__dark.png", files)
            return index

    def test_matrix_keeps_connection_screens_and_covers_the_catalog(self):
        keys = [(entry["scenario"], entry["appearance"], entry.get("variant")) for entry in MATRIX]
        self.assertEqual(len(keys), len(set(keys)))
        connection = {(s, a) for s, a, v in keys if not s.startswith("design-catalog") and v is None}
        self.assertEqual(connection, {(s, a) for s in ("connection-empty", "connection-failed", "console-online") for a in ("light", "dark")})
        for theme in ("evergreen", "ocean", "plum", "terracotta"):
            for appearance in ("light", "dark"):
                self.assertIn((f"design-catalog-{theme}", appearance, None), keys)
        self.assertTrue(any(entry["textSize"] != "standard" and entry["scenario"].startswith("design-catalog") for entry in MATRIX))
        self.assertTrue(any(entry["transparency"] != "system" for entry in MATRIX))

    def test_export_requires_and_indexes_complete_matrix(self):
        index = self.export()
        catalog = [item for item in index if item["surface"] == "design catalog"]
        self.assertTrue(catalog and all(item["theme"] and item["textSize"] and item["transparency"] for item in catalog))

    def test_export_fails_on_missing_scenario(self):
        with self.assertRaises(SystemExit):
            self.export(omit_last=True)

    def test_failed_iphone_pass_still_runs_ipad_then_fails(self):
        with self.assertRaises(SystemExit) as raised:
            self.export(fail_family="iPhone")
        self.assertIn("iPhone", str(raised.exception.code))
        self.assertEqual(sum(command[0] == "xcodebuild" for command in self.calls), 2)
        # Partial evidence is still exported and indexed for both devices.
        self.assertEqual({item["file"].split("__")[0] for item in self.partial_index}, {"iPhone", "iPad"})

    def test_export_rejects_unlisted_scenario(self):
        with self.assertRaises(SystemExit):
            self.export(extra={"scenario": "design-catalog-sunset", "appearance": "light"})


if __name__ == "__main__":
    unittest.main()
