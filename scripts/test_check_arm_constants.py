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

    def test_a_removed_direction_table_or_conversion_fails(self):
        for text, what in (
            ("let (axis, sign) = direction.baseAxis\n", "OperatorDirection.baseAxis"),
            ("public var baseAxis: (axis: BaseAxis, sign: Double) {\n    (.y, -1)\n}\n", "OperatorDirection.baseAxis"),
            ("let way = side.baseVector\n", "baseVector or linkVector property"),
            ("let sent = OperatorDirection.up.linkVector * 2\n", "baseVector or linkVector property"),
            ("let moved = OperatorFrame.link(fromBase: b)\n", "OperatorFrame's conversions"),
            ("let p = OperatorFrame.linkOffset(right: 0, forward: 0, up: 1)\n", "OperatorFrame's conversions"),
            ("let p = GuideProjection.operatorPoint(base)\n", "static GuideProjection conversions"),
            ("let b = GuideProjection.base(fromOperator: p)\n", "static GuideProjection conversions"),
        ):
            for relative in (APP, CORE):
                out = self.assertFails({relative: text}, what, f"{relative}: {text}")
                self.assertIn("put the number in the robot profile file", out)

    def test_a_direction_read_through_the_frames_passes(self):
        self.assertPasses(
            {
                APP: "let way = frames.baseVector(side)\nlet p = frames.linkVector(.up) * 2\n"
                "let q = projection.operatorPoint(base)\nlet m = GuideProjection.marginShare\n",
                CORE: "// the old baseAxis table and OperatorFrame are gone\nlet text = \"OperatorFrame.baseAxis\"\n",
            }
        )

    def test_a_removed_direction_table_passes_in_the_tests_and_the_documents(self):
        self.assertPasses(
            {
                APP_TEST: "let way = side.baseVector\nlet x = OperatorFrame.link(fromBase: b)\n",
                CORE_TEST: "let (axis, sign) = direction.baseAxis\n",
                "docs/PROFILE.md": "OperatorDirection.baseAxis is gone\n",
            }
        )

    def test_a_removed_wrist_or_jaw_number_fails(self):
        for text, what in (
            ("public static let turnRate = 20.0\n", "the wrist buttons' own rates"),
            ("case .tiltDown: return Self.tiltRate\n", "the wrist buttons' own rates"),
            ("let c = InputConstants.appendixA\n", "InputConstants.appendixA"),
            ("constants: InputConstants = .appendixA\n", "InputConstants.appendixA"),
            ("let open = profile.gripperOpenDeg\n", "the jaw thresholds in degrees"),
            ("if angle >= limits.openDeg { }\n", "the jaw thresholds in degrees"),
            ("if angle <= limits.emptyDeg { }\n", "the jaw thresholds in degrees"),
            ("var turnLimit = 55.0\n", "written as a default or a constant"),
            ("public var leadDeg = 2.0\n", "written as a default or a constant"),
            ("public var memoryDeg: Double = 0.5\n", "written as a default or a constant"),
            ("rollClampDeg: Double = 55, tiltClampDeg: Double = 20,\n", "written as a default or a constant"),
            ("static let rollWindowDeg = 150\n", "written as a default or a constant"),
            ("var rollSign: Double = 1\n", "written as a default or a constant"),
            ("let fullyOpenAt = 97\n", "written as a default or a constant"),
            ("var emptyAt: Double = 2\n", "written as a default or a constant"),
            ("let validMax = 360\n", "written as a default or a constant"),
        ):
            for relative in (APP, CORE):
                out = self.assertFails({relative: text}, what, f"{relative}: {text}")
                self.assertIn("put the number in the robot profile file", out)

    def test_a_wrist_or_jaw_read_from_the_profile_passes(self):
        self.assertPasses(
            {
                APP: "let limit = profile.wrist.rollClampDeg\nlet jaw = profile.gripper.fullyOpenAt\n"
                "var turnLimit: Double\nfacts.turnLimit = wrist.rollClampDeg\n"
                "let rate = button.degreesPerSecond(in: wrist)\nlet share = gripper.opening(at: 40)\n"
                "if leadDeg == 2 { }\nlet limits = GripperLimits(fullyOpenAt: a, emptyAt: b)\n",
                CORE: "// the old turnRate and appendixA and openDeg are gone\nlet text = \"emptyDeg = 2\"\n"
                "public static let freshStateMs = 400\n",
            }
        )

    def test_a_removed_wrist_or_jaw_number_passes_in_the_tests_and_the_documents(self):
        self.assertPasses(
            {
                APP_TEST: "var turnLimit = 55.0\nlet c = InputConstants.appendixA\nlet r = WristButton.turnRate\n",
                CORE_TEST: "let limits = GripperLimits(openDeg: 97, emptyDeg: 2)\nvar leadDeg = 2.0\n",
                "docs/PROFILE.md": "WristButton.turnRate = 20 and gripperOpenDeg were code\n",
            }
        )

    def test_a_wrist_or_jaw_built_or_held_in_code_fails(self):
        for relative, text in (
            (APP, "let w = WristProfile(rollSign: 1, tiltSign: 1)\n"),
            (CORE, "let j = GripperProfile(unit: .deg, closedReading: a)\n"),
            (APP, "let lead = WristLeadLimits.init(leadDeg: a)\n"),
            (APP, "static let jaw = GripperProfile.so101\n"),
            (CORE, "static let wrist: WristProfile = load()\n"),
            (APP, "private static var jaws: [GripperProfile] = []\n"),
        ):
            out = self.assertFails({relative: text}, "wrist or jaw", f"{relative}: {text}")
            self.assertIn("put the number in the robot profile file", out)

    def test_a_wrist_or_jaw_passed_around_or_built_in_the_profile_folder_or_tests_pass(self):
        self.assertPasses(
            {
                APP: "func use(_ wrist: WristProfile, jaw: GripperProfile) -> Double { wrist.rollSign }\n"
                "let wrist = profile.wrist\nlet jaws = [GripperProfile.Type.self]\n",
                PROFILE: "public struct WristProfile {}\nlet w = WristProfile(rollSign: 1)\n",
                APP_TEST: "static let jaw = GripperProfile(unit: .mm, closedReading: 0)\n",
                CORE_TEST: "static let wrist = WristProfile(rollSign: 1)\n",
            }
        )

    def test_a_removed_motion_or_response_number_fails(self):
        for text, what in (
            ("let cap = LiveLinkController.maxLeadMeters\n", "the link controller's lead caps"),
            ("static let toolMaxLeadMeters: Float = 0.005\n", "the link controller's lead caps"),
            ("if wait > Self.resyncTimeoutMs { }\n", "the link controller's resync times"),
            ("let after = toolControl ? Self.toolResyncAfterMs : Self.resyncAfterMs\n", "the link controller's resync times"),
            ("return speed.metresPerSecond * Double(ms) / 1000\n", "a button speed's own metresPerSecond"),
            ("if gap >= FeedbackMonitor.blockedShortMeters { }\n", "the feedback monitor's blocked and lowest statics"),
            ("let w = Self.blockedWindowMs + 1\n", "the feedback monitor's blocked and lowest statics"),
            ("static let lowestDescentMetersPerSecond = 0.0005\n", "the feedback monitor's blocked and lowest statics"),
            ("(0...FeedbackMonitor.freshStateMs).contains(age)\n", "the feedback monitor's blocked and lowest statics"),
            ("guard $1.atMs - $0.atMs <= FeedbackMonitor.arrivalGapMs\n", "the feedback monitor's blocked and lowest statics"),
            ("guard fix.ageS <= GoMove.freshS else { }\n", "the going move's statics"),
            ("drift += change * GoMove.followShare\n", "the going move's statics"),
            ("let g = GoMove.paceGain / swing\n", "the going move's statics"),
            ("let s = GoMove.pathWatchTolerances * tol\n", "the going move's statics"),
            ("var maxLeadM: Float = 0.08\n", "written as a default or a constant"),
            ("static let stopDistanceM = 0.10\n", "written as a default or a constant"),
            ("let followShare: Double = 0.5\n", "written as a default or a constant"),
            ("public var sameWayDeg = 45\n", "written as a default or a constant"),
            ("quickMs: Int = 300,\n", "written as a default or a constant"),
            ("var toolAfterMs = 500\n", "written as a default or a constant"),
        ):
            for relative in (APP, CORE):
                out = self.assertFails({relative: text}, what, f"{relative}: {text}")
                self.assertIn("put the number in the robot profile file", out)

    def test_a_removed_static_declared_again_or_read_through_self_inside_its_type_fails(self):
        monitor = "the feedback monitor's blocked and lowest statics"
        going = "the going move's statics"
        for text, what in (
            ("struct FeedbackMonitor {\n    static let freshStateMs = 400\n}\n", monitor),
            ("extension FeedbackMonitor {\n    private static let arrivalGapMs = 400\n}\n", monitor),
            ("final class FeedbackMonitor {\n    static var freshStateMs: Int { 400 }\n}\n", monitor),
            ("struct FeedbackMonitor {\n    func f(age: Int) -> Bool { age <= Self.freshStateMs }\n}\n", monitor),
            ("struct FeedbackMonitor {\n    func f(gap: Int) -> Bool { gap <= Self . arrivalGapMs }\n}\n", monitor),
            ("struct GoMove {\n    static let freshS = 0.4\n}\n", going),
            ("extension GoMove {\n    static let settleMoveM = 0.002\n}\n", going),
            ("struct GoMove {\n    func f(m: Double) -> Bool { m < Self.settleMoveM }\n}\n", going),
            ("struct GoMove {\n    static let paceGain: Double = 0.25\n}\n", going),
            ("struct GoMove {\n    let g = Self.followShare * 2\n}\n", going),
        ):
            for relative in (APP, CORE):
                out = self.assertFails({relative: text}, what, f"{relative}: {text}")
                self.assertIn("put the number in the robot profile file", out)

    def test_the_names_of_a_removed_static_pass_where_they_are_not_the_removed_static(self):
        self.assertPasses(
            {
                APP: "struct FeedbackMonitor {\n    let blockedRule: BlockedRule\n"
                "    func f(age: Int) -> Bool { age <= blockedRule.freshMs && Self.length(v) > 0 }\n}\n"
                "struct WristLeadLimits {\n    static let freshStateMs = wrist.lead.freshStateMs\n}\n"
                "struct Other {\n    func f() -> Int { Self.freshS }\n    static let arrivalGapMs: Int = limit()\n}\n",
                CORE: "struct GoMove {\n    let limits: GoToLimits\n    func f(t: Double) -> Bool { t <= limits.freshS }\n}\n",
                CORE_TEST: "struct FeedbackMonitor {\n    static let freshStateMs = 400\n    let a = Self.freshStateMs\n}\n",
            }
        )

    def test_a_motion_or_response_number_read_from_the_profile_passes(self):
        self.assertPasses(
            {
                APP: "let cap = profile.motion.maxLeadM\nlet after = server.resync.afterMs\n"
                "let fresh = blocked.freshMs\nlet rate = speed.metresPerSecond(in: motion)\n"
                "let ok = abs(x) <= pacing.stillM\nvar maxLeadM: Float\nfacts.maxLeadM = motion.maxLeadM\n"
                "if arrivalGapMs == 400 { }\nlet n = wrist.lead.freshStateMs\n",
                CORE: "// the old maxLeadMeters and GoMove.followShare are gone\nlet t = \"blockedShortMeters = 0.01\"\n"
                "public static let acceptMinMs = 100\nlet gap = rule.arrivalGapMs\n",
            }
        )

    def test_a_removed_motion_or_response_number_passes_in_the_tests_and_the_documents(self):
        self.assertPasses(
            {
                APP_TEST: "let c = LiveLinkController.maxLeadMeters\nvar maxLeadM: Float = 0.08\n",
                CORE_TEST: "var metresPerSecond: Double { 1 }\nlet f = FeedbackMonitor.blockedShortMeters\n"
                "let g = GoMove.followShare\nstatic let followShare = 0.5\n",
                "docs/PROFILE.md": "GoMove.paceGain = 0.25 and resyncAfterMs were code\n",
            }
        )

    def test_a_motion_or_response_profile_built_or_held_in_code_fails(self):
        for relative, text in (
            (APP, "let m = MotionProfile(fineMps: 0.01, coarseMps: 0.04)\n"),
            (CORE, "let s = ServerProfile(stopDistanceM: 0.1)\n"),
            (APP, "let r = ResyncTimes.init(afterMs: 1, toolAfterMs: 2, timeoutMs: 3)\n"),
            (CORE, "let b = BlockedRule(shortM: 0.01)\n"),
            (APP, "let l = LowestRule(sustainM: 0.005)\n"),
            (CORE, "let p = GoToPacing(followShare: 0.5)\n"),
            (APP, "static let motion = MotionProfile.so101\n"),
            (CORE, "static let blocked: BlockedRule = load()\n"),
            (APP, "private static var rules: [LowestRule] = []\n"),
        ):
            out = self.assertFails({relative: text}, "motion, server or response", f"{relative}: {text}")
            self.assertIn("put the number in the robot profile file", out)

    def test_a_motion_or_response_profile_passed_around_or_built_in_the_profile_folder_or_tests_pass(self):
        self.assertPasses(
            {
                APP: "func use(_ motion: MotionProfile, rule: BlockedRule) -> Double { motion.maxLeadM }\n"
                "let motion = profile.motion\nlet rules = [BlockedRule.Type.self]\n",
                PROFILE: "public struct MotionProfile {}\nlet m = MotionProfile(fineMps: 0.01)\n",
                APP_TEST: "static let motion = MotionProfile(fineMps: 0.01)\n",
                CORE_TEST: "static let pacing = GoToPacing(followShare: 0.5)\n",
            }
        )

    def test_frames_held_or_built_in_code_fail(self):
        for relative, text in (
            (APP, "static let arm = Frames(forward: f, left: l, up: u)\n"),
            (CORE, "public static let arm: Frames = make()\n"),
            (CORE, "static var frames: Frames { make() }\n"),
            (CORE, "static let frames: TeleopCore.Frames? = nil\n"),
            (APP, "static let arm = TeleopCore.Frames(forward: f, left: l, up: u)\n"),
            (APP, "static let arm = Frames.init(forward: f, left: l, up: u)\n"),
            (APP, "static let arm = Frames.so101\n"),
            (APP, "static let arm = profile.frames\n"),
            (APP, "static let arm = ProfileLoader.loaded.frames\n"),
            (CORE, "static var arm = frames\n"),
        ):
            self.assertFails({relative: text}, "robot frames held in a static", f"{relative}: {text}")
        for relative, text in (
            (APP, "let frames = Frames(forward: f, left: l, up: u)\n"),
            (CORE, "func make() -> Frames { Frames(forward: f, left: l, up: u) }\n"),
        ):
            self.assertFails({relative: text}, "robot frames built in code", f"{relative}: {text}")

    def test_statics_that_only_look_like_frames_pass(self):
        self.assertPasses(
            {
                APP: "static let kind = Frames.self\nstatic let count = profile.frames.count\n"
                "static let rate = player.framesPerSecond\nstatic let up = profile.frames.up\n"
                "static let name = \"Frames.so101\"\n// static let arm = Frames.so101\n",
            }
        )

    def test_frames_passed_around_or_built_in_the_profile_folder_or_tests_pass(self):
        self.assertPasses(
            {
                APP: "struct Rule { let frames: Frames\n    init(frames: Frames) { self.frames = frames }\n"
                "    static let limit = 3\n}\n",
                PROFILE: "func decode() -> Frames { Frames(forward: f, left: l, up: u) }\n"
                "public struct RobotProfile {\n    public var frames: Frames\n}\n",
                APP_TEST: "enum TestFrames {\n    static let b = Frames(forward: f, left: l, up: u)\n}\n",
                CORE_TEST: "enum TestFrames {\n    static let so: Frames = Frames(forward: f)\n}\n",
            }
        )

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
            "struct Note {\n    let id: Int,\n        offsetMeasuredAt: SIMD3<Float>\n}",
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
            {APP: 'let isBench = label == "SO-\\u{61}rm (bench)"\n'}
        )

    # Every static the batches removed, in the form it had: each fails if it comes back, in the app and in the core.
    REMOVED_STATICS = (
        # the profile constant
        ("extension RobotProfile {\n    static let so101Simulator = make()\n}\n", "the name so101Simulator"),
        # the direction table and conversions
        ("extension OperatorDirection {\n    var baseAxis: SignedAxis { .init(.y, -1) }\n}\n", "baseAxis"),
        ("enum OperatorFrame {\n    static func link(fromBase b: V) -> V { b }\n}\n", "OperatorFrame"),
        (
            "struct GuideProjection {\n    static func operatorPoint(_ p: V) -> V { p }\n}\n",
            "the static GuideProjection conversions",
        ),
        (
            "struct GuideProjection {\n    public static func base(fromOperator p: V) -> V { p }\n}\n",
            "the static GuideProjection conversions",
        ),
        # the wrist and the jaw
        ("struct WristButton {\n    public static let turnRate = 20.0\n}\n", "the wrist buttons' own rates"),
        ("struct WristButton {\n    public static let tiltRate = 10.0\n}\n", "the wrist buttons' own rates"),
        ("extension InputConstants {\n    public static let appendixA = InputConstants()\n}\n", "appendixA"),
        ("struct WristLeadBound {\n    public var leadDeg = 2.0\n}\n", "written as a default or a constant"),
        ("struct WristLeadBound {\n    public var rateMaxDegS = 10.0\n}\n", "written as a default or a constant"),
        ("struct WristLeadBound {\n    public var memoryDeg = 0.5\n}\n", "written as a default or a constant"),
        ("struct WristLeadBound {\n    public var freshStateMs = 400\n}\n", "the wrist lead bound's freshStateMs"),
        ("struct Jaw {\n    static let openDeg = 97\n}\n", "the jaw thresholds in degrees"),
        ("struct Jaw {\n    static let emptyDeg = 2\n}\n", "the jaw thresholds in degrees"),
        # the link controller's caps and times
        ("struct LiveLinkController {\n    static let maxLeadMeters: Float = 0.08\n}\n", "the link controller's lead caps"),
        ("struct LiveLinkController {\n    static let toolMaxLeadMeters: Float = 0.005\n}\n", "the link controller's lead caps"),
        ("struct LiveLinkController {\n    static let resyncAfterMs = 1500\n}\n", "the link controller's resync times"),
        ("struct LiveLinkController {\n    static let toolResyncAfterMs = 500\n}\n", "the link controller's resync times"),
        ("struct LiveLinkController {\n    static let resyncTimeoutMs = 1500\n}\n", "the link controller's resync times"),
        # the feedback monitor's statics
        ("struct FeedbackMonitor {\n    public static let blockedShortMeters = 0.010\n}\n", "the feedback monitor's blocked and lowest statics"),
        ("struct FeedbackMonitor {\n    public static let blockedMovedMeters = 0.002\n}\n", "the feedback monitor's blocked and lowest statics"),
        ("struct FeedbackMonitor {\n    public static let blockedWindowMs = 1000\n}\n", "the feedback monitor's blocked and lowest statics"),
        ("struct FeedbackMonitor {\n    public static let freshStateMs = 400\n}\n", "the feedback monitor's blocked and lowest statics"),
        ("struct FeedbackMonitor {\n    public static let arrivalGapMs = 400\n}\n", "the feedback monitor's blocked and lowest statics"),
        ("struct FeedbackMonitor {\n    public static let lowestQuickShortMeters = 0.005\n}\n", "the feedback monitor's blocked and lowest statics"),
        ("struct FeedbackMonitor {\n    public static let lowestQuickMovedMeters = 0.001\n}\n", "the feedback monitor's blocked and lowest statics"),
        ("struct FeedbackMonitor {\n    public static let lowestQuickMs = 300\n}\n", "the feedback monitor's blocked and lowest statics"),
        ("struct FeedbackMonitor {\n    public static let lowestSustainMeters = 0.005\n}\n", "the feedback monitor's blocked and lowest statics"),
        ("struct FeedbackMonitor {\n    public static let lowestDescentMetersPerSecond = 0.0005\n}\n", "the feedback monitor's blocked and lowest statics"),
        # the going move's statics
        ("struct GoMove {\n    static let freshS = Double(FeedbackMonitor.freshStateMs) / 1000\n}\n", "the going move's statics"),
        ("struct GoMove {\n    static let settleMoveM = FeedbackMonitor.blockedMovedMeters\n}\n", "the going move's statics"),
        ("struct GoMove {\n    static let followShare = 0.5\n}\n", "the going move's statics"),
        ("struct GoMove {\n    static let paceGain = 0.25\n}\n", "the going move's statics"),
        ("struct GoMove {\n    static let slowestShare = 0.15\n}\n", "the going move's statics"),
        ("struct GoMove {\n    static let startShare = 0.5\n}\n", "the going move's statics"),
        ("struct GoMove {\n    static let pathWatchTolerances = 2.5\n}\n", "the going move's statics"),
        # a button speed's own metres per second
        ("let v = speed.metresPerSecond * t\n", "a button speed's own metresPerSecond"),
    )

    def test_every_static_the_batches_removed_fails_if_it_comes_back(self):
        for text, what in self.REMOVED_STATICS:
            for relative in (APP, CORE):
                out = self.assertFails({relative: text}, what, f"{relative}: {text}")
                self.assertIn("put the number in the robot profile file", out)

    def test_a_removed_static_comes_back_in_a_test_or_a_document_and_passes(self):
        self.assertPasses(
            {
                APP_TEST: "".join(text for text, _ in self.REMOVED_STATICS),
                CORE_TEST: "".join(text for text, _ in self.REMOVED_STATICS),
                "docs/PROFILE.md": "so101Simulator, turnRate, maxLeadMeters and FeedbackMonitor.freshStateMs were code\n",
            }
        )

    def test_the_lead_bounds_fresh_state_ms_given_a_number_in_its_type_fails(self):
        what = "the wrist lead bound's freshStateMs"
        for text in (
            "struct WristLeadBound {\n    public var freshStateMs = 400\n}\n",
            "struct WristLeadBound {\n    var freshStateMs: Int = 400\n}\n",
            "extension WristLeadBound {\n    init() { self.init(freshStateMs: Int = 400) }\n}\n",
            "struct WristLeadLimits {\n    public var freshStateMs: Int = 400\n}\n",
            "struct WristLeadLimits {\n    public init(leadDeg: Double, freshStateMs: Int = 400) {}\n}\n",
        ):
            for relative in (APP, CORE):
                self.assertFails({relative: text}, what, f"{relative}: {text}")

    def test_the_lead_bounds_fresh_state_ms_read_from_the_profile_or_in_another_type_passes(self):
        self.assertPasses(
            {
                APP: "struct WristLeadBound {\n    public var freshStateMs: Int\n"
                "    init(limits: WristLeadLimits) { freshStateMs = limits.freshStateMs }\n}\n"
                "struct WristLeadLimits {\n    public var freshStateMs: Int\n}\n"
                "struct Other {\n    var freshStateMs = 400\n}\n",
                CORE_TEST: "let limits = WristLeadLimits(leadDeg: 2, freshStateMs: 300)\n",
            }
        )

    def test_a_branch_on_a_profiles_name_fails(self):
        for text in (
            'if profile.name == "other" { slow() }\n',
            "if model.profile.name != name { slow() }\n",
            "switch profile.name {\ncase \"a\": break\ndefault: break\n}\n",
            "guard profile.name.hasPrefix(prefix) else { return }\n",
            "let slow = profile.name.contains(word)\n",
            "let slow = profile.name == label\n",
            "let rate = profile.name == label ? 1 : 2\n",
            "while profile.name.isEmpty { wait() }\n",
        ):
            for relative in (APP, CORE):
                out = self.assertFails({relative: text}, "a branch on a robot profile's name", f"{relative}: {text}")
                self.assertIn("put the number in the robot profile file", out)

    def test_a_static_conversion_declared_again_inside_guide_projection_fails(self):
        what = "the static GuideProjection conversions"
        for text in (
            "struct GuideProjection {\n    static func operatorPoint(_ p: V) -> V { p }\n}\n",
            "struct GuideProjection {\n    public static func base(fromOperator p: V) -> V { p }\n}\n",
            "extension GuideProjection {\n    static func base(fromOperator p: V) -> V { p }\n}\n",
            "extension GuideProjection {\n    nonisolated static func operatorPoint(_ p: V) -> V { p }\n}\n",
            "struct GuideProjection {\n    func above(_ p: V) -> V { Self.operatorPoint(p) }\n}\n",
            "struct GuideProjection {\n    func below(_ p: V) -> V { Self . base(fromOperator: p) }\n}\n",
            "extension GuideProjection {\n    func x(_ p: V) -> V { Self.base(fromOperator: p) }\n}\n",
        ):
            for relative in (APP, CORE):
                self.assertFails({relative: text}, what, f"{relative}: {text}")

    def test_the_instance_conversions_of_guide_projection_and_other_types_pass(self):
        self.assertPasses(
            {
                CORE: "struct GuideProjection {\n"
                "    public func operatorPoint(_ p: V) -> V { frames.operatorPoint(p) }\n"
                "    public func base(fromOperator p: V) -> V { frames.base(fromOperator: p) }\n"
                "    private static func length(_ r: R) -> Double { r.upperBound }\n"
                "    func width() -> Double { Self.length(range) }\n}\n"
                "struct Other {\n    static func base(_ p: V) -> V { p }\n"
                "    func x(_ p: V) -> V { Self.base(p) }\n}\n",
                CORE_TEST: "struct GuideProjection {\n    static func base(fromOperator p: V) -> V { p }\n}\n",
            }
        )

    def test_a_branch_on_a_profiles_name_or_id_in_the_other_forms_fails(self):
        for text in (
            'if ProfileLoader.current.name == "x" { slow() }\n',
            "let slow = ProfileLoader.current.id == label\n",
            "let slow = ProfileLoader.current . name.hasPrefix(word)\n",
            "if robotProfile.name == other { slow() }\n",
            "if profile.id == other { slow() }\n",
            "if profile?.name == other { slow() }\n",
            "guard profile!.name != other else { return }\n",
            "func go(arm: RobotProfile) {\n    if arm.name == other { slow() }\n}\n",
            "func go(arm: TeleopCore.RobotProfile?) {\n    if arm?.name == other { slow() }\n}\n",
            "let p: RobotProfile\nif p.name == other { slow() }\n",
            "var held: RobotProfile\nlet slow = held.name.contains(word)\n",
            "let arm = RobotProfile(name: n)\nswitch arm.name { default: break }\n",
            "let n = profile.name\nif n == other { slow() }\n",
            "let n = profile.name\nlet slow = n.hasPrefix(word)\n",
            "let n = profile.name\nlet slow = other == n\n",
            "let n = profile.name\nswitch n {\ncase \"a\": break\ndefault: break\n}\n",
            "var n: String = arm.name\nwhile n.isEmpty { wait() }\n".replace("arm.name", "profile.name"),
            "if let n = profile?.name, n == other { slow() }\n",
            "switch\n    profile.name {\ncase \"a\": break\ndefault: break\n}\n".replace("switch\n    profile.name", "switch profile.name"),
            "switch profile.name\n{\ncase \"a\": break\ndefault: break\n}\n",
            "switch\n    profile.name\n{\ndefault: break\n}\n",
            "func go(arm: RobotProfile) {\n    let n = arm.name\n    if n == other { slow() }\n}\n",
        ):
            for relative in (APP, CORE):
                out = self.assertFails({relative: text}, "a branch on a robot profile's name or id", f"{relative}: {text}")
                self.assertIn("put the number in the robot profile file", out)

    def test_reading_a_profiles_name_without_deciding_by_it_passes(self):
        self.assertPasses(
            {
                APP: "let title = profile.name\n"
                "Text(profile.name)\n"
                "func go(arm: RobotProfile) {\n    let label = arm.name\n    print(label)\n    show(label)\n}\n"
                "let shown = profile.name\nlet louder = shown + \"!\"\nif count == 1 { show(shown) }\n"
                "func f(device: Device) {\n    if device.name == other { }\n    let n = device.name\n    if n == x { }\n}\n",
                APP_TEST: "let n = profile.name\nif n == other { }\nswitch profile.name { default: break }\n",
                CORE_TEST: "if arm.name == other { }\n",
            }
        )

    def test_showing_a_profiles_name_or_branching_on_a_name_in_a_test_passes(self):
        self.assertPasses(
            {
                APP: "let title = profile.name\nlog(\"driving \\(profile.name)\")\nlet names = devices.map(\\.name)\n"
                "if deviceProfile.name == other { }\nlet client = clientName\n",
                APP_TEST: 'if profile.name == "other" { }\nswitch profile.name { default: break }\n',
                CORE_TEST: "XCTAssertEqual(profile.name, name)\n",
            }
        )

    def test_a_branch_on_the_chosen_profile_id_fails(self):
        for text, what in (
            ("if ProfileLoader.chosenID() == other { slow() }\n", "the profile loader's choice"),
            ("let id = try ProfileLoader.chosenID()\n", "the profile loader's choice"),
            ("let p = try ProfileLoader.chosen()\n", "the profile loader's choice"),
            ("let p = try ProfileLoader.load(id: chosen)\n", "the profile loader's choice"),
            ("let key = ProfileLoader.infoKey\n", "the profile loader's choice"),
            ("let key = ProfileLoader.argumentKey\n", "the profile loader's choice"),
            (
                'let id = Bundle.main.object(forInfoDictionaryKey: "TeleopRobotProfile") as? String\n',
                "the build's profile choice",
            ),
            (
                'let id = UserDefaults.standard.string(forKey: "robotProfile")\n',
                "the build's profile choice",
            ),
            ('if id == "so-arm" { slow() }\n', "the profile id so-arm named outside the loader"),
            ('switch id { case "bench-b": slow() default: break }\n', "the profile id bench-b named outside the loader"),
            ('if name == "SO-arm (bench)" { slow() }\n', "the profile name 'SO-arm (bench)' written in code"),
        ):
            for relative in (APP, CORE):
                out = self.assertFails({relative: text}, what, f"{relative}: {text}")
                self.assertIn("put the number in the robot profile file", out)

    def test_the_loader_and_the_tests_may_read_the_choice(self):
        self.assertPasses(
            {
                "App/Sources/Link/ProfileLoader.swift": "static let infoKey = \"TeleopRobotProfile\"\n"
                'static let argumentKey = "robotProfile"\n'
                "static func chosen() throws -> RobotProfile { try load(id: chosenID()) }\n",
                APP_TEST: "let id = try ProfileLoader.chosenID()\nlet p = try ProfileLoader.chosen()\n"
                'let key = ProfileLoader.infoKey\nlet arg = ["-robotProfile", "so-arm"]\n',
                "project.yml": "TeleopRobotProfile: so-arm\n",
                "TestPlans/Default.xctestplan": '{"argument": "-robotProfile"}\n',
                "docs/PROFILE.md": "The launch argument -robotProfile and TeleopRobotProfile choose the file.\n",
            }
        )


if __name__ == "__main__":
    unittest.main()
