"""Offline checks of device selection and xcresult manifest export orchestration."""
import contextlib
import io
import json
import pathlib
import re
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

    def export(self, omit_last=False, extra=None, fail_family=None, family=None, focus=None, matrix=None, batch_size=None, export_failure=None, timeout_first=False):
        matrix = MATRIX if matrix is None else matrix
        # Copy only the executable into an isolated root; no real Artifacts or simulator use.
        (ROOT / ".build").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / ".build") as directory:
            root = pathlib.Path(directory)
            (root / "Tools").mkdir()
            shutil.copyfile(ROOT / "Tools/screenshots", root / "Tools/screenshots")
            shutil.copyfile(ROOT / "Tools/screenshot-matrix.json", root / "Tools/screenshot-matrix.json")
            if batch_size:
                (root / "AppUITests").mkdir()
                (root / "AppUITests/AccessibilityReviewTests.swift").write_text(
                    "func testFirst() {}\nfunc testSecond() {}\nfunc testThird() {}\n")
                (root / "AppUITests/AgentSettingsScenarioTests.swift").write_text(
                    "func testPage() {}\nfunc testPicker() {}\nfunc testNotifications() {}\n")
            calls = []
            run_options = []

            def fake_run(command, **kwargs):
                calls.append(command)
                run_options.append(kwargs)
                stdout = ""
                if command[0] == "xcodebuild":
                    bundle = pathlib.Path(command[command.index("-resultBundlePath") + 1])
                    bundle.mkdir(parents=True)
                    self.assertIn("-collect-test-diagnostics", command)
                    self.assertEqual(command[command.index("-collect-test-diagnostics") + 1], "never")
                    if timeout_first and bundle.name == "iPhone.xcresult":
                        raise subprocess.TimeoutExpired(command, kwargs.get("timeout"))
                    if fail_family and bundle.name == f"{fail_family}.xcresult":
                        raise subprocess.CalledProcessError(65, command)
                if command[:3] == ("xcrun", "simctl", "list"):
                    stdout = json.dumps(listing())
                if command[:4] == ("xcrun", "xcresulttool", "export", "attachments"):
                    destination = pathlib.Path(command[command.index("--output-path") + 1])
                    destination.mkdir()
                    first_bundle = pathlib.Path(command[command.index("--path") + 1]).name == "iPhone.xcresult"
                    if first_bundle and export_failure == "command":
                        raise subprocess.CalledProcessError(65, command)
                    attachments = []
                    entries = matrix[:-1] if omit_last else matrix
                    if batch_size:
                        result = pathlib.Path(command[command.index("--path") + 1]).stem
                        match = re.search(r"-batch-(\d+)$", result)
                        number = int(match.group(1)) if match else 1
                        entries = entries[number - 1::2]
                    for number, entry in enumerate(entries + ([extra] if extra else [])):
                        suffix = f"__{entry['variant']}" if entry.get("variant") else ""
                        label = f"synthetic-fixture__{entry['scenario']}__{entry['appearance']}{suffix}"
                        name = f"{number}.png"
                        (destination / name).write_bytes(b"synthetic export stub")
                        # xcresulttool appends an index and UUID to the attachment name.
                        attachments.append({"suggestedHumanReadableName": f"{label}_0_0F0E0D0C-0000-4000-8000-00000000000{number % 10}.png", "exportedFileName": name})
                    manifest = destination / "manifest.json"
                    manifest.write_text(json.dumps([{"attachments": attachments}]))
                    if first_bundle:
                        if export_failure == "missing":
                            manifest.unlink()
                        elif export_failure == "json":
                            manifest.write_text("not JSON")
                        elif export_failure == "shape":
                            manifest.write_text('[{"unexpected": []}]')
                if command[0] == "sips" and "-g" in command:
                    stdout = "pixelWidth: 1000\npixelHeight: 2000\n"
                return subprocess.CompletedProcess(command, 0, stdout=stdout)

            argv = ["screenshots", "--iphone", "phone", "--ipad", "pad"] + (["--family", family] if family else [])
            if focus:
                argv.extend(focus.split())
            if batch_size:
                argv.extend(["--batch-size", str(batch_size)])
            index_name = f"index-{family}" if family else "index"
            with patch.object(sys, "argv", argv), patch("subprocess.run", side_effect=fake_run), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                try:
                    runpy.run_path(str(root / "Tools/screenshots"), run_name="__main__")
                finally:
                    self.calls = calls
                    self.run_options = run_options
                    index_path = root / f"Artifacts/Screenshots/{index_name}.json"
                    self.partial_index = json.loads(index_path.read_text()) if index_path.exists() else None
            index = json.loads((root / f"Artifacts/Screenshots/{index_name}.json").read_text())
            count = 1 if family else 2
            self.assertEqual(len(index), count * len(matrix))
            self.assertTrue(all(item["label"] == "synthetic fixture" for item in index))
            self.assertEqual(sum(command[0] == "xcodebuild" for command in calls), count * (2 if batch_size else 1))
            self.assertEqual(sum(command[:3] == ("sips", "-Z", "2000") for command in calls), count * len(matrix))
            files = {item["file"] for item in index}
            if family != "iPad" and focus is None:
                self.assertIn("iPhone__connection-failed__light__ax3.png", files)
            if family != "iPhone" and focus is None:
                self.assertIn("iPad__design-catalog-reduce-transparency__dark.png", files)
            return index

    def test_review_batches_export_one_combined_exact_matrix(self):
        matrix = [entry for entry in MATRIX if
                  (entry["scenario"] in {"composer-model-selector", "skill-browser", "conversation-ask-form", "conversation-quick-replies", "peer-question-sheet"}
                   and entry.get("variant") in {"ax3", "opaque"})
                  or (entry["scenario"] == "connection-empty" and entry.get("variant") in {"editorax3", "editoropaque"})]
        self.export(family="iPhone", focus="--accessibility-only", matrix=matrix, batch_size=2)
        builds = [command for command in self.calls if command[0] == "xcodebuild"]
        selectors = [arg for command in builds for arg in command if arg.startswith("-only-testing:")]
        self.assertEqual(selectors, ["-only-testing:MonoAgentUITests/AccessibilityReviewTests/testFirst",
                                    "-only-testing:MonoAgentUITests/AccessibilityReviewTests/testSecond",
                                    "-only-testing:MonoAgentUITests/AccessibilityReviewTests/testThird"])

    def review_matrix(self):
        return [entry for entry in MATRIX if
                (entry["scenario"] in {"composer-model-selector", "skill-browser", "conversation-ask-form", "conversation-quick-replies", "peer-question-sheet"}
                 and entry.get("variant") in {"ax3", "opaque"})
                or (entry["scenario"] == "connection-empty" and entry.get("variant") in {"editorax3", "editoropaque"})]

    def test_bad_early_export_or_manifest_preserves_and_validates_later_bundle(self):
        matrix = self.review_matrix()
        for failure in ("command", "missing", "json", "shape"):
            with self.subTest(failure=failure), self.assertRaises(SystemExit) as raised:
                self.export(family="iPhone", focus="--accessibility-only", matrix=matrix,
                            batch_size=2, export_failure=failure)
            self.assertIn("iPhone.xcresult: export/manifest validation failed", str(raised.exception))
            self.assertEqual(len(self.partial_index), len(matrix[1::2]))
            self.assertEqual({(row["scenario"], row["appearance"], row["variant"]) for row in self.partial_index},
                             {(row["scenario"], row["appearance"], row.get("variant")) for row in matrix[1::2]})
            resized = [call for call in self.calls if call[:3] == ("sips", "-Z", "2000")]
            self.assertEqual(len(resized), len(matrix[1::2]))

    def test_timeout_records_failure_and_runs_later_batches_with_bounded_timeout(self):
        matrix = self.review_matrix()
        with self.assertRaises(SystemExit) as raised:
            self.export(family="iPhone", focus="--accessibility-only", matrix=matrix,
                        batch_size=2, timeout_first=True)
        self.assertIn("timed out after 1140 seconds", str(raised.exception))
        builds = [(call, options) for call, options in zip(self.calls, self.run_options)
                  if call[0] == "xcodebuild"]
        self.assertEqual(len(builds), 2)
        self.assertTrue(all(options["timeout"] == 19 * 60 for _, options in builds))
        self.assertEqual(len(self.partial_index), len(matrix))
        self.assertTrue(any("-only-testing:MonoAgentUITests/AccessibilityReviewTests/testThird" in call
                            for call, _ in builds))
        self.export(family="iPhone", focus="--accessibility-only", matrix=matrix)
        self.assertTrue(all(options.get("timeout") is None for call, options in
                            zip(self.calls, self.run_options) if call[0] == "xcodebuild"))

    def test_matrix_keeps_connection_screens_and_covers_the_catalog(self):
        keys = [(entry["scenario"], entry["appearance"], entry.get("variant")) for entry in MATRIX]
        self.assertEqual(len(keys), len(set(keys)))
        connection = {(s, a) for s, a, v in keys
                      if not s.startswith(("design-catalog", "dashboard-", "conversation-", "composer-", "peer-question", "fidelity-", "skill-browser", "project-", "tag-", "wake-", "organize-", "agent-settings", "notifications-"))
                      and v is None}
        self.assertEqual(connection, {(s, a) for s in ("connection-empty", "connection-failed", "console-online") for a in ("light", "dark")})
        for theme in ("evergreen", "ocean", "plum", "terracotta"):
            for appearance in ("light", "dark"):
                self.assertIn((f"design-catalog-{theme}", appearance, None), keys)
        self.assertTrue(any(entry["textSize"] != "standard" and entry["scenario"].startswith("design-catalog") for entry in MATRIX))
        self.assertTrue(any(entry["transparency"] != "system" for entry in MATRIX))

    def test_console_variants_have_connection_surface_and_variant_metadata(self):
        rows = [row for row in self.export(family="iPhone")
                if row["scenario"] == "dashboard-populated" and (row.get("variant") or "").startswith("consoles")]
        self.assertEqual(len(rows), 10)
        for row in rows:
            self.assertEqual(row["surface"], "connection")
            self.assertEqual(row["textSize"], "accessibility XL (AX3)" if "ax3" in row["variant"] else "standard")
            self.assertEqual(row["theme"], "evergreen")
            self.assertEqual(row["transparency"], "system")

    def test_export_classifies_organize_surfaces(self):
        index = self.export(family="iPhone")
        for prefix, surface in (("project-", "project"), ("tag-", "tag"), ("wake-", "wake schedule"), ("organize-", "conversation")):
            rows = [item for item in index if item["scenario"].startswith(prefix)]
            self.assertTrue(rows)
            self.assertTrue(all(item["surface"] == surface for item in rows))

    def test_matrix_covers_organize_surfaces(self):
        keys = {(entry["scenario"], entry["appearance"], entry.get("variant")) for entry in MATRIX}
        for scenario, variants in (("conversation-actions", (None,)),
                                   ("project-page", (None,)),
                                   ("project-settings", ("create", "edit")),
                                   ("tag-menu", (None,)),
                                   ("tag-settings", ("create", "edit")),
                                   ("wake-new", (None,)), ("wake-weekly", (None,)),
                                   ("wake-conflict", (None,)), ("wake-once", (None, "status"))):
            for variant in variants:
                for appearance in ("light", "dark"):
                    self.assertIn((scenario, appearance, variant), keys)

    def test_matrix_covers_fidelity_screens_and_additional_surfaces(self):
        keys = {(entry["scenario"], entry["appearance"], entry.get("variant")) for entry in MATRIX}
        for scenario in ("fidelity-chat", "fidelity-dashboard", "skill-browser", "peer-question"):
            for appearance in ("light", "dark"):
                self.assertIn((scenario, appearance, None), keys)
        self.assertIn(("conversation-jobs", "light", "failed"), keys)
        for scenario in ("composer-model-selector", "skill-browser", "conversation-ask-form",
                         "conversation-quick-replies", "peer-question-sheet"):
            self.assertIn((scenario, "light", "ax3"), keys)
            self.assertIn((scenario, "light", "opaque"), keys)

    def test_matrix_covers_dashboard_scenarios_themes_and_accessibility(self):
        keys = {(entry["scenario"], entry["appearance"], entry.get("variant")) for entry in MATRIX}
        for scenario in ("dashboard-populated", "dashboard-empty", "dashboard-offline",
                         "dashboard-search", "conversation-placeholder"):
            for appearance in ("light", "dark"):
                self.assertIn((scenario, appearance, None), keys)
        dashboard = [entry for entry in MATRIX if entry["scenario"].startswith("dashboard-")]
        self.assertTrue(any(entry["theme"] != "evergreen" for entry in dashboard))
        self.assertTrue(any(entry["textSize"] != "standard" for entry in dashboard))

    def test_matrix_covers_composer_scenarios_keyboard_theme_and_accessibility(self):
        keys = {(entry["scenario"], entry["appearance"], entry.get("variant")) for entry in MATRIX}
        for scenario in ("composer-empty", "composer-draft-attachments", "composer-skill-picker",
                         "composer-model-selector", "composer-running", "composer-send-failed",
                         "composer-quote", "conversation-ask-form", "conversation-quick-replies",
                         "peer-question-sheet"):
            for appearance in ("light", "dark"):
                self.assertIn((scenario, appearance, None), keys)
        self.assertIn(("composer-empty", "light", "keyboard"), keys)
        composer = [entry for entry in MATRIX if entry["scenario"].startswith("composer-")]
        self.assertTrue(any(entry["theme"] != "evergreen" for entry in composer))
        self.assertTrue(any(entry["textSize"] != "standard" for entry in composer))

    def test_ci_family_leg_runs_only_one_device_and_uses_collision_free_index(self):
        for family in ("iPhone", "iPad"):
            with self.subTest(family=family):
                index = self.export(family=family)
                self.assertEqual({row["file"].split("__")[0] for row in index}, {family})

    def test_activity_only_runs_exact_activity_matrix(self):
        matrix = [entry for entry in MATRIX if entry["scenario"] in {
            "conversation-jobs", "conversation-job-stack", "conversation-subagents", "conversation-context", "peer-question"}
            or (entry["scenario"] == "conversation-markdown" and entry.get("variant") == "context")]
        self.export(family="iPhone", focus="--activity-only", matrix=matrix)
        command = next(call for call in self.calls if call[0] == "xcodebuild")
        self.assertIn("-only-testing:MonoAgentUITests/ActivityScenarioTests", command)

    def test_accessibility_only_runs_exact_review_matrix(self):
        matrix = [entry for entry in MATRIX if
                  (entry["scenario"] in {"composer-model-selector", "skill-browser", "conversation-ask-form", "conversation-quick-replies", "peer-question-sheet"}
                   and entry.get("variant") in {"ax3", "opaque"})
                  or (entry["scenario"] == "connection-empty" and entry.get("variant") in {"editorax3", "editoropaque"})]
        expected = {(scenario, "light", variant)
                    for scenario in ("composer-model-selector", "skill-browser", "conversation-ask-form", "conversation-quick-replies", "peer-question-sheet")
                    for variant in ("ax3", "opaque")} | {("connection-empty", "light", "editorax3"), ("connection-empty", "dark", "editorax3"),
                                                         ("connection-empty", "light", "editoropaque")}
        self.assertEqual({(e["scenario"], e["appearance"], e.get("variant")) for e in matrix}, expected)
        self.export(family="iPhone", focus="--accessibility-only", matrix=matrix)
        command = next(call for call in self.calls if call[0] == "xcodebuild")
        self.assertIn("-only-testing:MonoAgentUITests/AccessibilityReviewTests", command)

    AGENT_SETTINGS_BASE = ("agent-settings", "agent-settings-unsaved", "agent-settings-save-error",
                           "agent-settings-offline", "agent-settings-degraded",
                           "notifications-explainer", "notifications-insecure")

    def agent_settings_keys(self):
        keys = {(scenario, appearance, None) for scenario in self.AGENT_SETTINGS_BASE for appearance in ("light", "dark")}
        keys |= {("agent-settings", appearance, variant) for appearance in ("light", "dark") for variant in ("ax3", "opaque", "picker")}
        return keys

    def test_matrix_covers_exact_agent_settings_scenarios_and_metadata(self):
        entries = {(e["scenario"], e["appearance"], e.get("variant")): e for e in MATRIX
                   if e["scenario"].startswith(("agent-settings", "notifications-"))}
        self.assertEqual(set(entries), self.agent_settings_keys())
        for (scenario, appearance, variant), entry in entries.items():
            self.assertEqual(entry["theme"], "evergreen")
            self.assertEqual(entry["textSize"], "accessibility XL (AX3)" if variant == "ax3" else "standard")
            self.assertEqual(entry["transparency"], "opaque fallback" if variant == "opaque" else "system")

    def test_export_classifies_agent_settings_and_notifications(self):
        index = self.export(family="iPad")
        for prefix, surface in (("agent-settings", "agent settings"), ("notifications-", "notifications")):
            rows = [item for item in index if item["scenario"].startswith(prefix)]
            self.assertTrue(rows)
            self.assertTrue(all(item["surface"] == surface for item in rows))
        ax3 = next(item for item in index if item["scenario"] == "agent-settings" and item["variant"] == "ax3")
        self.assertEqual(ax3["textSize"], "accessibility XL (AX3)")

    def test_agent_settings_only_runs_its_suite_and_exact_matrix_on_both_families(self):
        matrix = [entry for entry in MATRIX if entry["scenario"].startswith(("agent-settings", "notifications-"))]
        self.assertEqual({(e["scenario"], e["appearance"], e.get("variant")) for e in matrix}, self.agent_settings_keys())
        for family in ("iPhone", "iPad"):
            with self.subTest(family=family):
                index = self.export(family=family, focus="--agent-settings-only", matrix=matrix)
                self.assertEqual(len(index), len(matrix))
                command = next(call for call in self.calls if call[0] == "xcodebuild")
                self.assertIn("-only-testing:MonoAgentUITests/AgentSettingsScenarioTests", command)
                self.assertEqual(sum(arg.startswith("-only-testing:") for arg in command), 1)

    def test_agent_settings_only_batches_enumerate_only_its_suite(self):
        matrix = [entry for entry in MATRIX if entry["scenario"].startswith(("agent-settings", "notifications-"))]
        index = self.export(family="iPad", focus="--agent-settings-only", matrix=matrix, batch_size=2)
        self.assertEqual({(row["scenario"], row["appearance"], row["variant"]) for row in index},
                         self.agent_settings_keys())
        builds = [command for command in self.calls if command[0] == "xcodebuild"]
        selectors = [arg for command in builds for arg in command if arg.startswith("-only-testing:")]
        self.assertEqual(selectors, ["-only-testing:MonoAgentUITests/AgentSettingsScenarioTests/testPage",
                                    "-only-testing:MonoAgentUITests/AgentSettingsScenarioTests/testPicker",
                                    "-only-testing:MonoAgentUITests/AgentSettingsScenarioTests/testNotifications"])
        self.assertTrue(all(options["timeout"] == 19 * 60 for call, options in
                            zip(self.calls, self.run_options) if call[0] == "xcodebuild"))

    def test_default_run_keeps_the_whole_test_plan(self):
        self.export(family="iPhone")
        command = next(call for call in self.calls if call[0] == "xcodebuild")
        self.assertFalse(any(arg.startswith("-only-testing:") for arg in command))

    def test_focus_flags_are_mutually_exclusive(self):
        with self.assertRaises(SystemExit):
            self.export(family="iPhone", focus="--agent-settings-only --accessibility-only")

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
