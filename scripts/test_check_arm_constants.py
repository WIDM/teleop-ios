"""Run with: python3 -m unittest scripts/test_check_arm_constants.py"""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parent / "check-arm-constants.py"

APP = "App/Sources/Arms.swift"
CORE = "Packages/TeleopCore/Sources/TeleopCore/Rules/Arms.swift"
PROFILE = "Packages/TeleopCore/Sources/TeleopCore/Profile/RobotProfile.swift"
APP_TEST = "Tests/TeleopTests/ArmTests.swift"
CORE_TEST = "Packages/TeleopCore/Tests/TeleopCoreTests/ArmTests.swift"


class CheckArmConstantsTests(unittest.TestCase):
    """Each case is a small tree with one bundled profile file, so-arm ("SO-arm (bench)"), one test-only profile,
    bench-b ("Bench arm B"), and the given files."""

    def run_check(self, files):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "App/Resources/Profiles").mkdir(parents=True)
            (root / "App/Resources/Profiles/so-arm.json").write_text(
                '{"name": "SO-arm (bench)"}\n'
            )
            (root / "Tests/TeleopTests/Profiles").mkdir(parents=True)
            (root / "Tests/TeleopTests/Profiles/bench-b.json").write_text(
                '{"name": "Bench arm B"}\n'
            )
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

    def assertFails(self, files, message, case=None):
        code, out = self.run_check(files)
        self.assertEqual(code, 1, f"{case or files}\n{out}")
        self.assertIn(message, out, case or files)
        return out

    def assertPasses(self, files, case=None):
        code, out = self.run_check(files)
        self.assertEqual(code, 0, f"{case or files}\n{out}")

    def test_a_clean_tree_passes(self):
        self.assertPasses(
            {
                "App/Sources/AppModel.swift": "init(profile: RobotProfile = ProfileLoader.current) {}\n",
                "App/Sources/Operating/OperatingFixtures.swift": "private static let profile = ProfileLoader.current\n",
                "App/Sources/Link/ProfileLoader.swift": 'static let current: RobotProfile = load(id: "so-arm")\n',
                "Tests/TeleopTests/TestProfiles.swift": 'static let so101: RobotProfile = load(id: "so-arm")\n',
                "project.yml": "TeleopRobotProfile: so-arm\n",
                PROFILE: "public struct RobotProfile {\n    public static let formatVersion = 1\n}\n",
            }
        )

    def test_the_name_so101Simulator_fails_in_any_scanned_file(self):
        for relative, text in (
            (
                "App/Sources/Link/Guidance.swift",
                "extension RobotProfile {\n    static let so101Simulator = make()\n}\n",
            ),
            ("scripts/replay.py", "profile = 'so101Simulator'\n"),
            ("scripts/run.sh", "echo so101Simulator\n"),
        ):
            out = self.assertFails(
                {relative: text}, "the name so101Simulator", relative
            )
            self.assertIn("put the number in the robot profile file", out)
            self.assertIn("docs/PROFILE.md", out)

    def test_the_name_so101Simulator_passes_in_the_tests(self):
        self.assertPasses({APP_TEST: "// no so101Simulator here any more\n"})

    def test_a_static_profile_fails_however_it_is_written(self):
        for text in (
            'static let benchArm = RobotProfile(name: "B")',
            "static var benchArm: RobotProfile { make() }",
            "    public static let other: RobotProfile = make()",
            "static let bench = RobotProfile.init(name: x)",
            "static let bench = TeleopCore.RobotProfile(name: x)",
            "static let bench: TeleopCore.RobotProfile = make()",
            "static let bench =\n    RobotProfile(name: x)",
            "enum Legacy {\n    static let alternate =\n        RobotProfile(name: x)\n}",
            "static let bench:\n    RobotProfile = make()",
            "static let spare: RobotProfile? = nil",
            "static let all: [RobotProfile] = []",
            "static let byID: [String: RobotProfile] = [:]",
            "static private(set) var bench: RobotProfile = make()",
            "nonisolated static let bench: RobotProfile = make()",
            "static let all: [\n    RobotProfile\n] = []",
            "static let byID: [\n    String: RobotProfile\n] = [:]",
            "static var pair: (\n    Int,\n    TeleopCore.RobotProfile\n)? = nil",
            "static let a = 1, b: RobotProfile = make()",
            "static let a: Int = 1,\n    b = RobotProfile(name: x)",
            "static let cache = Dictionary<String, Int>(), arm: RobotProfile = make()",
            "static let pairs = [Int: Set<String>](), arm = RobotProfile(name: x)",
            "static let ok = (2 > 1), arm: RobotProfile = make()",
        ):
            self.assertFails({APP: text + "\n"}, "a robot profile held in code", text)

    def test_other_types_across_lines_and_other_bindings_pass(self):
        for text in (
            "static let all: [\n    String\n] = []\nlet p = profile",
            "static let a = 1, b: Int = 2",
            "static let a: Int = 1,\n    b = make(profile)",
            "static let handler: (\n    RobotProfile.Type\n) -> Void = { _ in }",
            "static let cache = Dictionary<String, Int>(), count: Int = 0",
            "static let ok = a < b, other = 1",
            "static let count = consume(2 > 1, profiles: [Int]())",
        ):
            self.assertPasses({APP: text + "\n"}, text)

    def test_a_static_profile_in_the_profile_folder_fails_too(self):
        self.assertFails(
            {PROFILE: "enum Arms {\n    static let bench: RobotProfile = make()\n}\n"},
            "RobotProfile.swift:2: a robot profile held in code",
        )

    def test_metatypes_nested_types_protocols_and_actors_pass(self):
        for text in (
            "static let modelType: RobotProfile.Type = RobotProfile.self",
            "static let model = RobotProfile.self",
            "static let inner: RobotProfile.Inner = .init()",
            "extension RobotProfile {\n    struct Inner {\n        static let none = Self()\n    }\n}",
            "extension RobotProfile {\n    enum Kind {\n        static var all: Self { .a }\n    }\n}",
            "extension RobotProfile {}\n\nprotocol Arm {\n    static var spare: Self { get }\n}",
            "extension RobotProfile {}\n\nactor Recorder {\n    static let shared = Self()\n}",
            "extension RobotProfile {}\n\n@MainActor final class Box {\n    static let shared: Self = .init()\n}",
            "struct Other {\n    static let none = Self()\n}",
        ):
            self.assertPasses({APP: text + "\n"}, text)

    def test_a_static_self_inside_the_profile_type_fails(self):
        for text in (
            'extension RobotProfile {\n    static let arm = Self(name: "A")\n}',
            "extension RobotProfile {\n    static var arm: Self { make() }\n}",
            "public extension TeleopCore.RobotProfile {\n    static let arm =\n        .init(name: x)\n}",
            "extension RobotProfile: Sendable {\n    struct Inner {}\n    static let arm = Self.init(name: x)\n}",
            "extension RobotProfile {\n    static let all: [\n        Self\n    ] = []\n}",
            "extension RobotProfile {\n    static let arm: RobotProfile = .init(name: x)\n}",
        ):
            self.assertFails(
                {PROFILE: text + "\n"}, "a robot profile held in code", text
            )

    def test_a_static_of_another_type_inside_the_profile_type_passes(self):
        self.assertPasses(
            {
                PROFILE: "extension RobotProfile {\n"
                "    static let zero: SIMD3<Float> = .init(repeating: 0)\n"
                "    static let id = 1, unit: SIMD3<Float> = .init(1, 0, 0)\n"
                "}\n"
            }
        )

    def test_a_profile_built_outside_the_profile_folder_fails(self):
        for relative, text in (
            (
                APP,
                'let benchArm = RobotProfile(name: "B", toolOffset: x, baseInWorld: y)',
            ),
            (
                APP,
                "init(profile: RobotProfile = RobotProfile(name: n, toolOffset: x)) {}",
            ),
            (APP, "let p = TeleopCore.RobotProfile.init(name: n)"),
            (APP, "let p = makeArm(name: n, offsetMeasuredAt: m)"),
            (APP, "var p = build(\n    name: n,\n    offsetMeasuredAt: m\n)"),
            (APP, "let p: RobotProfile = .init(name: n)"),
            (APP, "var p: RobotProfile? = .init(name: n)"),
            (APP, "func bench() -> RobotProfile {\n    .init(name: n)\n}"),
            (APP, "func bench() -> RobotProfile { return .init(name: n) }"),
            (
                APP,
                "let model = AppModel(profile: .init(name: n, toolOffset: x, offsetMeasuredAt: y))",
            ),
            (
                APP,
                "extension RobotProfile {\n    init(bench: Void) { self.init(name: n) }\n}",
            ),
            (
                APP,
                "extension RobotProfile {\n    func moved() -> RobotProfile { Self(name: n) }\n}",
            ),
            (APP, "let p =\n    RobotProfile(name: n)"),
            (CORE, "let p = RobotProfile(name: n)"),
            (
                APP,
                "func bench() throws -> TeleopCore.RobotProfile {\n"
                "    guard ok else { throw Failure() }\n    return .init(name: n)\n}",
            ),
            (
                APP,
                "struct Maker {\n    func make() -> RobotProfile {\n        .init(name: n)\n    }\n}",
            ),
            (
                APP,
                "struct Fake {\n    var offsetMeasuredAt: Date\n}\n"
                "let model = AppModel(profile: .init(name: n, offsetMeasuredAt: y))",
            ),
            (
                APP,
                "extension RobotProfile {\n    var moved: Self { .init(name: n) }\n}",
            ),
            (
                APP,
                "extension RobotProfile {\n    func moved() -> Self {\n"
                "        if flag { return .init(name: n) }\n        return self\n    }\n}",
            ),
            (
                APP,
                "extension RobotProfile {\n    var moved: RobotProfile {\n        get { .init(name: n) }\n    }\n}",
            ),
            (
                APP,
                "extension RobotProfile {\n    func moved() -> RobotProfile? {\n        switch kind {\n"
                "        case .a: return .init(name: n)\n        default: return nil\n        }\n    }\n}",
            ),
        ):
            self.assertFails(
                {relative: text + "\n"}, "a robot profile built in code", text
            )

    def test_the_loader_may_name_and_hold_a_profile_but_not_build_one(self):
        loader = "App/Sources/Link/ProfileLoader.swift"
        for text in (
            "let p = RobotProfile(name: n)",
            "static let current: RobotProfile = .init(name: n)",
            "static func spare() -> RobotProfile { .init(name: n) }",
            "let model = AppModel(profile: .init(name: n, offsetMeasuredAt: y))",
        ):
            self.assertFails(
                {loader: text + "\n"}, "a robot profile built in code", text
            )
        self.assertPasses(
            {
                loader: (
                    'static let fallback = "so-arm"\n'
                    "static let current: RobotProfile = {\n"
                    "    try! RobotProfile.load(json: data)\n"
                    "}()\n"
                    "static func load(id: String) throws -> RobotProfile {\n"
                    "    try RobotProfile.load(json: Data(contentsOf: url(id)))\n"
                    "}\n"
                )
            }
        )

    def test_a_field_or_another_types_init_is_not_a_profile_built(self):
        for text in (
            "struct Note {\n    let offsetMeasuredAt: SIMD3<Float>\n}",
            "struct Note {\n    let id: Int, offsetMeasuredAt: SIMD3<Float>\n}",
            "struct Note {\n    private(set) var id = 0, offsetMeasuredAt: Date?\n}",
            "struct Note { let id: Int, offsetMeasuredAt: SIMD3<Float> }",
            "struct Note {\n    public var offsetMeasuredAt: Date?\n}",
            "extension RobotProfile {\n    var vector: SIMD3<Float> { .init(repeating: 0) }\n}",
            "extension RobotProfile {\n    func origin() -> SIMD3<Float> {\n"
            "        return .init(repeating: 0)\n    }\n}",
            "extension RobotProfile {\n    var bound: EstimateBound {\n"
            "        if ok { .init(x: 1) } else { .init(x: 2) }\n    }\n}",
            "extension RobotProfile {\n    func moved() -> Self {\n"
            "        let v: SIMD3<Float> = .init(repeating: 0)\n        return with(v)\n    }\n}",
            "let v: SIMD3<Float> = .init(repeating: 0)",
            "draw(at: .init(x: 1, y: 2))",
            "struct Other {\n    func make() -> Self { .init() }\n}",
        ):
            self.assertPasses({APP: text + "\n"}, text)

    def test_a_profile_built_in_the_profile_folder_or_a_test_passes(self):
        text = (
            "let a = RobotProfile(name: n, toolOffset: x, offsetMeasuredAt: y)\n"
            "let b: RobotProfile = .init(name: n)\n"
            "extension RobotProfile {\n    init(other: Void) { self.init(name: n) }\n}\n"
        )
        for relative in (
            "Packages/TeleopCore/Sources/TeleopCore/Profile/ProfileFormat.swift",
            APP_TEST,
            CORE_TEST,
        ):
            self.assertPasses({relative: text}, relative)

    def test_a_profile_in_a_comment_a_string_or_a_property_read_passes(self):
        self.assertPasses(
            {
                APP: (
                    "// RobotProfile(name:) and static let x: RobotProfile live in the core.\n"
                    "/* static let bench = RobotProfile(name: n) */\n"
                    'let help = "RobotProfile(name:) builds one; static let x: RobotProfile"\n'
                    'let raw = #"RobotProfile("#\n'
                    'let block = """\n    static let x = RobotProfile(name: n)\n    """\n'
                    "let at = profile.offsetMeasuredAt\n"
                    "let profile = try RobotProfile.load(json: data)\n"
                    'let interpolated = "\\(profile.name) at \\(f("x"))"\n'
                ),
            }
        )

    def test_a_profile_id_outside_the_loader_fails(self):
        out = self.assertFails(
            {
                "App/Sources/Operating/Fixtures.swift": 'let p = try ProfileLoader.load(id: "so-arm")\n',
                "Packages/TeleopCore/Sources/TeleopServerModel/Config.swift": "// matches so-arm.json\n",
            },
            "Fixtures.swift:1: the profile id so-arm named outside the loader",
        )
        self.assertIn("Config.swift:1: the profile id so-arm", out)

    def test_a_test_only_profile_id_in_app_code_fails(self):
        self.assertFails(
            {APP: 'let p = try ProfileLoader.load(id: "bench-b")\n'},
            "the profile id bench-b named outside the loader",
        )

    def test_a_profile_id_in_a_test_passes(self):
        self.assertPasses(
            {APP_TEST: 'let a = load(id: "so-arm")\nlet b = load(id: "bench-b")\n'}
        )

    def test_a_longer_name_that_contains_an_id_is_not_it(self):
        self.assertPasses({APP: 'let name = "so-arm-2"\nlet other = "my-so-arm"\n'})

    def test_a_profile_name_in_code_fails(self):
        for text in (
            'if profile.name.hasPrefix("SO-arm") { slow() }',
            'if profile.name == "SO-arm (bench)" { slow() }',
            'let isBench = profile.name.contains("Bench arm B")',
            'let isBench = profile.name.hasPrefix("Bench arm")',
            'let label = "Driving SO-arm (bench) now"',
        ):
            self.assertFails({APP: text + "\n"}, "written in code", text)
        self.assertFails(
            {"scripts/plot.py": "TITLE = 'SO-arm (bench)'\n"},
            "the profile name 'SO-arm (bench)' written in code",
        )

    def test_a_profile_name_in_a_comment_a_test_or_a_short_word_passes(self):
        self.assertPasses(
            {
                APP: (
                    "// Measured on the SO-arm (bench).\n"
                    'let title = profile.name\nlet word = "Bench"\nlet other = "SO-armed"\n'
                ),
                APP_TEST: 'XCTAssertEqual(profile.name, "SO-arm (bench)")\n',
            }
        )

    def test_reading_the_current_profile_elsewhere_fails(self):
        for relative, text in (
            ("App/Sources/Link/Guidance.swift", "let p = ProfileLoader.current\n"),
            (
                "App/Sources/Operating/Rules.swift",
                "let p = ProfileLoader\n    .current.toolOffset\n",
            ),
            (CORE, "let p = ProfileLoader.current\n"),
            (APP_TEST, "let p = ProfileLoader.current\n"),
            (
                "App/Sources/Link/ProfileLoader.swift",
                "static var name: String { ProfileLoader.current.name }\n",
            ),
        ):
            self.assertFails(
                {relative: text},
                "ProfileLoader.current read outside AppModel and OperatingFixtures",
                relative,
            )

    def test_reading_the_current_profile_where_it_is_handed_out_passes(self):
        self.assertPasses(
            {
                "App/Sources/AppModel.swift": "init(profile: RobotProfile = ProfileLoader.current) {}\n",
                "App/Sources/Operating/OperatingFixtures.swift": "static let profile = ProfileLoader.current\n",
                "App/Sources/Link/ProfileLoader.swift": "static let current: RobotProfile = chosen()\n",
                APP: "// Comes from ProfileLoader.current, through AppModel.\nlet id = ProfileLoader.currentID\n",
            }
        )

    def test_a_name_spelled_with_swift_escapes_is_left_to_review(self):
        """The documented limit: the check guards against accidents, not deliberate evasion. This pins it, so a change
        in what the check catches is seen."""
        self.assertPasses(
            {APP: 'let isBench = profile.name == "SO-\\u{61}rm (bench)"\n'}
        )


if __name__ == "__main__":
    unittest.main()
