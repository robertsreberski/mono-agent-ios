"""Offline regression tests for the actual-binary fixture gate."""
import contextlib
import io
import pathlib
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2]


class ReleaseFixtureTests(unittest.TestCase):
    def check(self, leak_tool=None, leak=b"ScriptedTransport"):
        (ROOT / ".build").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / ".build") as directory:
            app = pathlib.Path(directory)
            (app / "MonoAgent").write_bytes(b"synthetic executable stub")
            calls = []

            def run(command, **kwargs):
                calls.append(command[1])
                output = b"ordinary app symbols"
                if command[1] == leak_tool:
                    output = b"ordinary symbols " + leak
                return subprocess.CompletedProcess(command, 0, stdout=output)

            with patch.object(sys, "argv", ["check-release-fixtures", "--app", str(app)]), patch("subprocess.run", side_effect=run), contextlib.redirect_stdout(io.StringIO()):
                runpy.run_path(str(ROOT / "Tools/check-release-fixtures"), run_name="__main__")
            self.assertEqual(calls, ["nm", "strings"])

    def test_clean_binary_requires_both_symbol_and_string_checks(self):
        self.check()

    def test_fixture_symbol_is_rejected(self):
        with self.assertRaises(SystemExit):
            self.check("nm")

    def test_fixture_string_is_rejected(self):
        with self.assertRaises(SystemExit):
            self.check("strings", b"console.example.ts.net")

    def test_design_catalog_symbols_and_scenarios_are_rejected(self):
        for tool, leak in (("nm", b"$s9MonoAgent17DesignCatalogViewV"), ("strings", b"design-catalog-ocean"),
                           ("nm", b"DesignPreviewMatrix")):
            with self.subTest(tool=tool, leak=leak), self.assertRaises(SystemExit):
                self.check(tool, leak)

    def test_store_scenarios_and_transports_are_rejected(self):
        for tool, leak in (("nm", b"StoreScenario"), ("nm", b"ScenarioConsoleTransport"),
                           ("nm", b"ScenarioEventSource"), ("strings", b"store-offline"),
                           ("strings", b"store-streaming"), ("strings", b"store-unread"),
                           ("strings", b"store-uncertain")):
            with self.subTest(tool=tool, leak=leak), self.assertRaises(SystemExit):
                self.check(tool, leak)

    def test_composer_fixture_and_scenarios_are_rejected(self):
        for tool, leak in (("nm", b"$s9MonoAgent15ComposerFixtureO"), ("nm", b"ComposerScript"),
                           ("strings", b"composer-send-failed"), ("strings", b"conversation-ask-form"),
                           ("strings", b"peer-question-sheet"), ("strings", b"Sample files (synthetic)")):
            with self.subTest(tool=tool, leak=leak), self.assertRaises(SystemExit):
                self.check(tool, leak)

    def test_fidelity_fixture_and_scenarios_are_rejected(self):
        for tool, leak in (("nm", b"ScreenFixture"), ("strings", b"fidelity-chat"),
                           ("strings", b"fidelity-dashboard"), ("strings", b"Map three beds")):
            with self.subTest(tool=tool, leak=leak), self.assertRaises(SystemExit):
                self.check(tool, leak)

    def test_dashboard_fixture_and_scenarios_are_rejected(self):
        for tool, leak in (("nm", b"$s9MonoAgent16DashboardFixtureO"), ("strings", b"dashboard-populated"),
                           ("strings", b"dashboard-empty"), ("strings", b"dashboard-offline"),
                           ("strings", b"dashboard-search"), ("strings", b"conversation-placeholder"),
                           ("strings", b"--fixture-theme")):
            with self.subTest(tool=tool, leak=leak), self.assertRaises(SystemExit):
                self.check(tool, leak)

    def test_mcp_fixture_symbols_and_content_are_rejected(self):
        for tool, leak in (("nm", b"McpGardenFixture"), ("strings", b"Garden planner (synthetic)"),
                           ("strings", b"garden-invocation"), ("strings", b"mcpCompleteInitialLoad"),
                           ("strings", b"mcpBufferState"), ("nm", b"debugSendAttempts"), ("nm", b"McpUiScript"),
                           ("nm", b"McpUiDiagnostics"), ("strings", b"conversation-mcp-app"),
                           ("strings", b"conversation-mcp-unavailable"), ("strings", b"conversation-mcp-long-title")):
            with self.subTest(tool=tool, leak=leak), self.assertRaises(SystemExit):
                self.check(tool, leak)

    def test_mcp_test_resources_are_rejected_even_without_binary_markers(self):
        (ROOT / ".build").mkdir(exist_ok=True)
        for name in ("mcp-protocol-vectors.json", "ext-apps-LICENSE.txt"):
            with tempfile.TemporaryDirectory(dir=ROOT / ".build") as directory:
                app = pathlib.Path(directory)
                (app / "MonoAgent").write_bytes(b"synthetic executable stub")
                (app / name).write_text("test-only material")
                with patch.object(sys, "argv", ["check-release-fixtures", "--app", str(app)]), self.assertRaises(SystemExit):
                    runpy.run_path(str(ROOT / "Tools/check-release-fixtures"), run_name="__main__")
