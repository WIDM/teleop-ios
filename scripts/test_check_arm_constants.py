"""Run with: python3 -m unittest scripts/test_check_arm_constants.py"""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parent / "check-arm-constants.py"


class CheckArmConstantsTests(unittest.TestCase):
    """Each case is a small tree with one profile file, so-arm, and the given files."""

    def run_check(self, files):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "App/Resources/Profiles").mkdir(parents=True)
            (root / "App/Resources/Profiles/so-arm.json").write_text("{}\n")
            for relative, text in files.items():
                (root / relative).parent.mkdir(parents=True, exist_ok=True)
                (root / relative).write_text(text)
            result = subprocess.run(
                [sys.executable, str(SCRIPT)],
                env={**os.environ, "CHECK_ARM_CONSTANTS_ROOT": str(root)},
                capture_output=True,
                text=True,
            )
            return result.returncode, result.stdout

    def test_a_clean_tree_passes(self):
        code, out = self.run_check(
            {
                "App/Sources/AppModel.swift": "init(profile: RobotProfile = ProfileLoader.current) {}\n",
                "App/Sources/Link/ProfileLoader.swift": 'static let current: RobotProfile = load(id: "so-arm")\n',
                "Tests/TeleopTests/TestProfiles.swift": 'static let so101: RobotProfile = load(id: "so-arm")\n',
                "project.yml": "TeleopRobotProfile: so-arm\n",
                "Packages/TeleopCore/Sources/TeleopCore/Profile/RobotProfile.swift": "public struct RobotProfile {\n    public static let formatVersion = 1\n}\n",
            }
        )
        self.assertEqual(code, 0, out)

    def test_the_removed_constant_fails(self):
        code, out = self.run_check(
            {
                "App/Sources/Link/Guidance.swift": "extension RobotProfile {\n    static let so101Simulator = make()\n}\n",
            }
        )
        self.assertEqual(code, 1, out)
        self.assertIn(
            "App/Sources/Link/Guidance.swift:2: the removed constant so101Simulator",
            out,
        )
        self.assertIn("put the number in the robot profile file", out)
        self.assertIn("docs/PROFILE.md", out)

    def test_a_static_profile_fails_however_it_is_written(self):
        for line in (
            'static let benchArm = RobotProfile(name: "B")',
            "static var benchArm: RobotProfile { make() }",
            "    public static let other: RobotProfile = make()",
        ):
            code, out = self.run_check({"App/Sources/Arms.swift": line + "\n"})
            self.assertEqual(code, 1, line)
            self.assertIn("a robot profile held in code", out)

    def test_a_static_self_inside_the_profile_type_fails(self):
        code, out = self.run_check(
            {
                "Packages/TeleopCore/Sources/TeleopCore/Profile/RobotProfile.swift": 'extension RobotProfile {\n    static let arm = Self(name: "A")\n}\n',
            }
        )
        self.assertEqual(code, 1, out)
        self.assertIn("RobotProfile.swift:2: a robot profile held in code", out)

    def test_a_static_self_in_another_type_passes(self):
        code, out = self.run_check(
            {
                "App/Sources/Other.swift": "extension RobotProfile {}\n\nstruct Other {\n    static let none = Self()\n}\n",
            }
        )
        self.assertEqual(code, 0, out)

    def test_a_profile_id_outside_the_loader_fails(self):
        code, out = self.run_check(
            {
                "App/Sources/Operating/Fixtures.swift": 'let p = try ProfileLoader.load(id: "so-arm")\n',
                "Packages/TeleopCore/Sources/TeleopServerModel/Config.swift": "// matches so-arm.json\n",
            }
        )
        self.assertEqual(code, 1, out)
        self.assertIn(
            "Fixtures.swift:1: the profile id so-arm named outside the loader", out
        )
        self.assertIn("Config.swift:1: the profile id so-arm", out)

    def test_a_longer_name_that_contains_an_id_is_not_it(self):
        code, out = self.run_check(
            {
                "App/Sources/Other.swift": 'let name = "so-arm-2"\nlet other = "my-so-arm"\n'
            }
        )
        self.assertEqual(code, 0, out)


if __name__ == "__main__":
    unittest.main()
