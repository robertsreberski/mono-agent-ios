"""CI graph and merged screenshot evidence without simulators or third-party packages."""
import json
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class CIMatrixTests(unittest.TestCase):
    def test_yaml_graph_requires_both_legs_and_merged_artifact(self):
        # Ruby's bundled YAML parser checks syntax; no Python YAML dependency.
        script = """
require 'yaml'
w = YAML.safe_load(File.read(ARGV[0]))
j = w.fetch('jobs')
raise unless j['ios-tests']['strategy']['matrix']['family'] == ['iPhone', 'iPad']
raise unless j['ios-tests']['strategy']['fail-fast'] == false
raise unless j['screenshots']['needs'] == ['ios-tests']
raise unless j['required']['needs'].sort == ['quality', 'host-tests', 'ios-tests', 'screenshots'].sort
raise unless j['required']['if'] == 'always()'
"""
        subprocess.run(["ruby", "-e", script, str(ROOT / ".github/workflows/ci.yml")], check=True, cwd=ROOT)

    def test_merge_requires_complete_family_indexes(self):
        matrix = json.loads((ROOT / "Tools/screenshot-matrix.json").read_text())["entries"]
        (ROOT / ".build").mkdir(exist_ok=True)  # fresh CI checkouts have no .build
        with tempfile.TemporaryDirectory(dir=ROOT / ".build") as directory:
            output = pathlib.Path(directory)
            for family in ("iPhone", "iPad"):
                rows = []
                for entry in matrix:
                    file = f"{family}__{entry['scenario']}__{entry['appearance']}" + (f"__{entry['variant']}" if entry.get('variant') else '') + '.png'
                    (output / file).write_bytes(b"synthetic test placeholder")
                    rows.append(dict(file=file, device=family, runtime="iOS synthetic", label="synthetic fixture",
                                     dimensions=[100, 200], **{key: entry[key] for key in ('scenario', 'appearance', 'theme', 'textSize', 'transparency')}))
                (output / f"index-{family}.json").write_text(json.dumps(rows))
            subprocess.run([str(ROOT / "Tools/merge-screenshots"), directory], check=True, cwd=ROOT, capture_output=True)
            self.assertEqual(len(json.loads((output / "index.json").read_text())), 2 * len(matrix))
            (output / "index-iPad.json").write_text("[]")
            result = subprocess.run([str(ROOT / "Tools/merge-screenshots"), directory], cwd=ROOT, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
