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
        """`profile` is the bundled file: JSON, or the text of one when a test needs a file `json.dumps` cannot write."""
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "docs").mkdir()
            (root / "App/Resources/Profiles").mkdir(parents=True)
            (root / "docs/PROFILE.md").write_text(guide)
            (root / PROFILE).write_text(profile if isinstance(profile, str) else json.dumps(profile))
            done = subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True, text=True)
            return done.returncode, done.stdout

    def guide(self, printed, naming=PROFILE):
        """A guide whose 'The whole file' section names `naming` and prints `printed` (JSON, or text)."""
        body = printed if isinstance(printed, str) else json.dumps(printed, indent=2)
        return f"# Guide\n\n```json\n{{}}\n```\n\n## The whole file\n\n`{naming}`, as it is.\n\n```json\n{body}\n```\n"

    def test_the_repository_guide_matches_the_bundled_file(self):
        done = subprocess.run([sys.executable, str(SCRIPT), str(REPO)], capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stdout)

    def test_a_copy_that_matches_passes(self):
        code, _ = self.run_check(self.guide({"a": [1, 2], "b": {"c": True}}), {"b": {"c": True}, "a": [1, 2]})
        self.assertEqual(code, 0)

    def test_a_changed_value_fails(self):
        code, out = self.run_check(self.guide({"a": 1}), {"a": 2})
        self.assertEqual(code, 1)
        self.assertIn("differs from App/Resources/Profiles/arm.json", out)

    def test_a_missing_block_fails(self):
        code, out = self.run_check("# Guide\n\nNothing printed.\n", {"a": 1})
        self.assertEqual(code, 1)
        self.assertIn("The whole file", out)

    def test_a_key_twice_in_the_printed_copy_fails(self):
        code, out = self.run_check(self.guide('{"profile_version": 1, "profile_version": 1}'), {"profile_version": 1})
        self.assertEqual(code, 1)
        self.assertIn("'profile_version' appears twice", out)

    def test_a_key_twice_in_the_bundled_file_fails(self):
        code, out = self.run_check(self.guide({"profile_version": 1}), '{"profile_version": 1, "profile_version": 1}')
        self.assertEqual(code, 1)
        self.assertIn("'profile_version' appears twice", out)

    def test_a_key_twice_in_a_nested_object_fails(self):
        code, out = self.run_check(self.guide('{"a": {"b": 1, "b": 2}}'), {"a": {"b": 2}})
        self.assertEqual(code, 1)
        self.assertIn("'b' appears twice", out)

    def test_true_printed_for_a_number_fails(self):
        code, out = self.run_check(self.guide({"profile_version": True}), {"profile_version": 1})
        self.assertEqual(code, 1)
        self.assertIn("differs from", out)

    def test_one_printed_for_a_boolean_fails(self):
        code, out = self.run_check(self.guide({"lock": 1, "list": [1]}), {"lock": True, "list": [1]})
        self.assertEqual(code, 1)
        self.assertIn("differs from", out)

    def test_a_boolean_inside_a_list_is_told_from_a_number(self):
        code, _ = self.run_check(self.guide({"list": [True]}), {"list": [1]})
        self.assertEqual(code, 1)

    def test_booleans_that_match_pass(self):
        code, _ = self.run_check(self.guide({"lock": True, "off": False, "n": 0}), {"lock": True, "off": False, "n": 0})
        self.assertEqual(code, 0)

    def test_a_copy_of_another_bundled_file_fails(self):
        """The guide names one file; matching a different bundled file is not enough."""
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "docs").mkdir()
            (root / "App/Resources/Profiles").mkdir(parents=True)
            (root / "docs/PROFILE.md").write_text(self.guide({"a": 1}))
            (root / PROFILE).write_text(json.dumps({"a": 2}))
            (root / "App/Resources/Profiles/other.json").write_text(json.dumps({"a": 1}))
            done = subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True, text=True)
        self.assertEqual(done.returncode, 1, done.stdout)
        self.assertIn("differs from App/Resources/Profiles/arm.json", done.stdout)

    def test_a_guide_that_names_no_file_fails(self):
        guide = "# Guide\n\n## The whole file\n\nAs it is.\n\n```json\n{}\n```\n"
        code, out = self.run_check(guide, {})
        self.assertEqual(code, 1)
        self.assertIn("does not name the profile file", out)

    def test_a_guide_that_names_a_missing_file_fails(self):
        code, out = self.run_check(self.guide({}, naming="App/Resources/Profiles/gone.json"), {})
        self.assertEqual(code, 1)
        self.assertIn("gone.json", out)
        self.assertIn("does not exist", out)
