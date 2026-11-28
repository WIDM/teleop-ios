"""Run with: python3 -m unittest scripts/test_check_profile_doc.py"""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parent / "check-profile-doc.py"
REPO = Path(__file__).resolve().parent.parent
PROFILE = "App/Resources/Profiles/arm.json"


class CheckProfileDocTests(unittest.TestCase):
    def run_check(self, guide, profile):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "docs").mkdir()
            (root / "App/Resources/Profiles").mkdir(parents=True)
            (root / "docs/PROFILE.md").write_text(guide)
            (root / PROFILE).write_text(json.dumps(profile))
            done = subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True, text=True)
            return done.returncode, done.stdout

    def guide(self, printed):
        return "# Guide\n\n```json\n{}\n```\n\n## The whole file\n\n```json\n" + json.dumps(printed, indent=2) + "\n```\n"

    def test_the_repository_guide_matches_the_bundled_file(self):
        done = subprocess.run([sys.executable, str(SCRIPT), str(REPO)], capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stdout)

    def test_a_copy_that_matches_passes(self):
        code, _ = self.run_check(self.guide({"a": [1, 2], "b": {"c": True}}), {"b": {"c": True}, "a": [1, 2]})
        self.assertEqual(code, 0)

    def test_a_changed_value_fails(self):
        code, out = self.run_check(self.guide({"a": 1}), {"a": 2})
        self.assertEqual(code, 1)
        self.assertIn("none of the bundled files", out)

    def test_a_missing_block_fails(self):
        code, out = self.run_check("# Guide\n\nNothing printed.\n", {"a": 1})
        self.assertEqual(code, 1)
        self.assertIn("The whole file", out)
