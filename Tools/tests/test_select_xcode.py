"""Offline tests of stable Xcode selection, including runner symlinks to beta bundles."""
import contextlib
import io
import os
import pathlib
import plistlib
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2]


class SelectXcodeTests(unittest.TestCase):
    def select(self, layout):
        """layout: name -> (version, symlink target name or None, plist version string)."""
        with tempfile.TemporaryDirectory() as directory:
            applications = pathlib.Path(directory) / "Applications"
            applications.mkdir()
            for name, (_, target, short) in layout.items():
                if target is None:
                    (applications / name / "Contents/Developer").mkdir(parents=True)
                    (applications / name / "Contents/version.plist").write_bytes(
                        plistlib.dumps({"CFBundleShortVersionString": short}))
            for name, (_, target, _) in layout.items():
                if target is not None:
                    (applications / name).symlink_to(applications / target)
            versions = {(applications / name).resolve() / "Contents/Developer": version
                        for name, (version, _, _) in layout.items()}
            github_env = pathlib.Path(directory) / "github_env"

            def version_for(env):
                return versions[pathlib.Path(env["DEVELOPER_DIR"])]

            def run(command, env=None, **kwargs):
                return subprocess.CompletedProcess(command, 0, stdout=f"Xcode {version_for(env)}\nBuild version 27X1\n")

            def check_output(command, env=None, **kwargs):
                if command[:2] == ["xcrun", "swift"]:
                    return "Apple Swift version 6.4 (swiftlang-6.4)\n"
                return f"Xcode {version_for(env)}\nBuild version 27X1\n"

            with patch.object(sys, "argv", ["select-xcode", "--applications", str(applications)]), \
                    patch.dict(os.environ, {"GITHUB_ENV": str(github_env)}), \
                    patch("subprocess.run", side_effect=run), \
                    patch("subprocess.check_output", side_effect=check_output), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                runpy.run_path(str(ROOT / "Tools/select-xcode"), run_name="__main__")
            selected = github_env.read_text().strip().removeprefix("DEVELOPER_DIR=")
            return pathlib.Path(selected).relative_to(applications.resolve()).parts[0]

    def test_symlink_named_stable_but_pointing_at_beta_is_skipped(self):
        layout = {
            "Xcode_27.2_beta_2.app": ("27.2", None, "27.2"),
            "Xcode_27.2.app": ("27.2", "Xcode_27.2_beta_2.app", None),
            "Xcode_27.1.app": ("27.1", None, "27.1"),
            "Xcode.app": ("27.2", "Xcode_27.2_beta_2.app", None),
        }
        self.assertEqual(self.select(layout), "Xcode_27.1.app")

    def test_newest_stable_wins(self):
        layout = {"Xcode_27.0.app": ("27.0", None, "27.0"), "Xcode_27.1.app": ("27.1", None, "27.1")}
        self.assertEqual(self.select(layout), "Xcode_27.1.app")

    def test_beta_version_metadata_is_skipped(self):
        layout = {"Xcode_27.3.app": ("27.3", None, "27.3 beta"), "Xcode_27.1.app": ("27.1", None, "27.1")}
        self.assertEqual(self.select(layout), "Xcode_27.1.app")

    def test_only_betas_fail_instead_of_falling_back(self):
        layout = {
            "Xcode_27.2_beta_2.app": ("27.2", None, "27.2"),
            "Xcode_27.2.app": ("27.2", "Xcode_27.2_beta_2.app", None),
        }
        with self.assertRaises(SystemExit) as raised:
            self.select(layout)
        self.assertIn("stable", str(raised.exception.code))


if __name__ == "__main__":
    unittest.main()
