"""Run with: python3 -m unittest scripts/test_check_strings.py"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parent / "check-strings.py"


def catalog(entries):
    unit = lambda value: {"stringUnit": {"state": "translated", "value": value}}
    return {
        "sourceLanguage": "en",
        "strings": {key: {"localizations": {"en": unit(en), "zh-Hant": unit(zh)}} for key, (en, zh) in entries.items()},
    }


class CheckStringsTests(unittest.TestCase):
    """Each case is a small app tree: the Swift source and the Localizable entries."""

    def run_check(self, swift, localizable):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for part in ("App/Sources", "App/Resources", "Tests/TeleopTests", "Packages/TeleopCore/Sources"):
                (root / part).mkdir(parents=True)
            (root / "App/Sources/Screen.swift").write_text(swift)
            (root / "App/Resources/Localizable.xcstrings").write_text(json.dumps(catalog(localizable)))
            for name in ("Buttons", "Speech", "InfoPlist"):
                (root / f"App/Resources/{name}.xcstrings").write_text(json.dumps(catalog({})))
            (root / "project.yml").write_text("name: Test\n")
            result = subprocess.run(
                [sys.executable, str(SCRIPT)], env={**os.environ, "CHECK_STRINGS_ROOT": str(root)},
                capture_output=True, text=True,
            )
            return result.returncode, result.stdout

    def test_a_clean_tree_passes(self):
        code, out = self.run_check('Text("settings.mode")\n', {"settings.mode": ("Mode", "模式")})
        self.assertEqual(code, 0, out)

    def test_an_identifier_equal_to_a_key_is_not_a_use_of_it(self):
        code, out = self.run_check(
            'Text("settings.title").accessibilityIdentifier("settings.mode")\n',
            {"settings.title": ("Settings", "設定"), "settings.mode": ("Mode", "模式")},
        )
        self.assertEqual(code, 1, out)
        self.assertIn("Localizable: unused settings.mode", out)

    def test_an_identifier_that_is_no_key_is_not_missing(self):
        code, out = self.run_check(
            'Text("settings.title").accessibilityIdentifier("settings.done")\n', {"settings.title": ("Settings", "設定")}
        )
        self.assertEqual(code, 0, out)

    def test_format_specifiers_must_come_in_the_same_order(self):
        code, out = self.run_check(
            'Text("guide.wrist")\n', {"guide.wrist": ("Turn %d°, tilt %@", "傾斜 %@，轉 %d°")}
        )
        self.assertEqual(code, 1, out)
        self.assertIn("guide.wrist format specifiers differ", out)

    def test_a_literal_percent_takes_no_argument(self):
        code, out = self.run_check(
            'Text("guide.jaws")\n', {"guide.jaws": ("%d%% open of %@", "%@ 張開 %d%%")}
        )
        self.assertEqual(code, 1, out)
        code, out = self.run_check(
            'Text("guide.jaws")\n', {"guide.jaws": ("%d%% of %@", "%d 個 %@，%%")}
        )
        self.assertEqual(code, 0, out)

    def test_numbered_format_specifiers_may_come_in_any_order(self):
        code, out = self.run_check(
            'Text("guide.wrist")\n', {"guide.wrist": ("Turn %1$d°, tilt %2$@", "傾斜 %2$@，轉 %1$d°")}
        )
        self.assertEqual(code, 0, out)


if __name__ == "__main__":
    unittest.main()
