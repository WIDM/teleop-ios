import Foundation
import XCTest

@testable import TeleopCore

/// The profile file's format is strict: every key must be written, an unknown key is refused, and each fault in the
/// values is reported in a sentence that names its field.
final class ProfileFormatTests: XCTestCase {
    /// A complete profile of a made-up arm, every optional value given, so every key of the format appears once.
    static let sample = """
        {
          "profile_version": 1,
          "name": "Test arm",
          "robot": {
            "directions": { "forward": "+x", "left": "-y", "up": "-z" },
            "wrist": {
              "roll_sign": -1, "tilt_sign": 1, "roll_window_deg": 90, "tilt_window_deg": 45, "roll_clamp_deg": 40,
              "tilt_clamp_deg": 30, "tilt_centre_deg": 15, "turn_rate_deg_s": 40, "tilt_rate_deg_s": 20,
              "lead": { "lead_deg": 3, "rate_max_deg_s": 20, "memory_deg": 1, "fresh_state_ms": 300 }
            },
            "gripper": {
              "unit": "mm", "closed_reading": 0, "open_reading": 40, "valid_min": 0, "valid_max": 45,
              "fully_open_at": 39, "empty_at": 1, "reclose_loosens_grip": false
            }
          },
          "server": { "link_signs": [1, 1, 1] },
          "scene": {
            "base_in_world_m": [0.1, 0.2, 0.3],
            "base_axes_in_world": { "x": "+y", "y": "+x", "z": "-z" },
            "table_height_m": 0.02,
            "workspace_min_m": [-0.1, -0.3, 0.0],
            "workspace_max_m": [0.1, -0.1, 0.2],
            "target_size_m": 0.03,
            "goal_size_m": 0.06,
            "grasp_tolerance_m": [0.005, 0.007],
            "on_target_window_m": [0.01, 0.012],
            "tool_offset": {
              "offset_m": [0.0, 0.0, -0.1],
              "measured_at_m": [0.0, -0.2, 0.1],
              "measured_flex_deg": 30,
              "measured_roll_deg": 0,
              "error_bound": {
                "x_mm_per_cm": 1, "plus_y_mm_per_cm": 2, "minus_y_mm_per_cm": 3, "z_mm_per_cm": 4,
                "flex_mm_per_deg": 0.5, "roll_mm_per_deg": 0.25
              }
            }
          },
          "response": { "directional_blocked_feedback": false },
          "assist": {
            "lock": { "time_limit_s": 20 },
            "go_to": {
              "travel_height_m": 0.04, "speed_mps": 0.03, "arrive_tolerance_m": 0.006, "corrections": 1,
              "correction_reach_m": 0.02, "settle_s": 0.5, "time_factor": 2, "allowance_s": 2,
              "arm_data_timeout_s": 1.5, "start_grace_s": 1
            },
            "guide": {
              "work_area_words": true, "lowest_cue": false, "shadow": true, "direction_labels": false,
              "wider_on_target": true
            },
            "explain": { "slow_link_let_go": true },
            "views": { "behind_top_above_table_m": 0.08, "max_retargeted_move_s": 20 }
          }
        }
        """

    private func object(_ json: String = sample) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func decode(_ object: [String: Any]) throws -> RobotProfile {
        try JSONDecoder().decode(RobotProfile.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func error(_ object: [String: Any], file: StaticString = #filePath, line: UInt = #line)
        -> ProfileFormatError?
    {
        do {
            _ = try decode(object)
            XCTFail("decoded", file: file, line: line)
            return nil
        } catch let error as ProfileFormatError {
            return error
        } catch {
            XCTFail("\(error)", file: file, line: line)
            return nil
        }
    }

    /// Every key path of the sample, such as `scene.tool_offset.offset_m`.
    private func paths(_ object: [String: Any], prefix: [String] = []) -> [[String]] {
        object.keys.sorted().flatMap { key -> [[String]] in
            let path = prefix + [key]
            guard let nested = object[key] as? [String: Any] else { return [path] }
            return [path] + paths(nested, prefix: path)
        }
    }

    private func changing(_ object: [String: Any], at path: [String], _ change: (inout [String: Any]) -> Void)
        -> [String: Any]
    {
        var copy = object
        guard path.count > 1 else {
            change(&copy)
            return copy
        }
        let nested = copy[path[0]] as? [String: Any] ?? [:]
        copy[path[0]] = changing(nested, at: Array(path.dropFirst()), change)
        return copy
    }

    func testTheSampleDecodesAndIsValid() throws {
        let profile = try RobotProfile.load(json: Data(Self.sample.utf8))
        XCTAssertEqual(profile.name, "Test arm")
        XCTAssertEqual(profile.toolOffset, SIMD3(0, 0, -0.1))
        XCTAssertEqual(profile.graspTolerance, SIMD2(0.005, 0.007))
        XCTAssertEqual(profile.onTargetWindow, SIMD2(0.01, 0.012))
        XCTAssertEqual(profile.rollSign, -1)
        XCTAssertEqual(profile.wrist, TestWrist.benchB)
        XCTAssertEqual(profile.gripper, TestJaw.benchB)
        XCTAssertEqual(profile.gripper.validReadings, 0...45)
        var expected = TestFrames.benchB
        expected.baseInWorld = SIMD3(0.1, 0.2, 0.3)
        XCTAssertEqual(profile.frames, expected)
        XCTAssertEqual(profile.baseInWorld, SIMD3<Float>(0.1, 0.2, 0.3))
        XCTAssertEqual(profile.assist.goTo?.corrections, 1)
        XCTAssertEqual(profile.assist.views?.maxRetargetedMoveS, 20)
        XCTAssertEqual(profile.validate(), [])
    }

    /// Written out and read back, a profile is the same value, nulls included.
    func testAProfileRoundTrips() throws {
        var profile = try RobotProfile.load(json: Data(Self.sample.utf8))
        XCTAssertEqual(try JSONDecoder().decode(RobotProfile.self, from: JSONEncoder().encode(profile)), profile)
        profile.onTargetWindow = nil
        profile.assist = .none
        XCTAssertEqual(try JSONDecoder().decode(RobotProfile.self, from: JSONEncoder().encode(profile)), profile)
    }

    func testEachMissingKeyIsRefusedByItsPath() throws {
        let sample = try object()
        let all = paths(sample)
        XCTAssertGreaterThan(all.count, 50)
        for path in all {
            let without = changing(sample, at: path) { $0[path.last!] = nil }
            XCTAssertEqual(error(without), .missingKey(path.joined(separator: ".")), path.joined(separator: "."))
        }
    }

    func testAnUnknownKeyIsRefusedAtEveryLevel() throws {
        let sample = try object()
        let objects =
            [[]]
            + paths(sample).filter { path in
                (path.reduce(sample as Any) { ($0 as? [String: Any])?[$1] }) is [String: Any]
            }
        for path in objects {
            let extra = changing(sample, at: path + ["gripper_degs"]) { $0["gripper_degs"] = 1 }
            XCTAssertEqual(
                error(extra), .unknownKey((path + ["gripper_degs"]).joined(separator: ".")),
                path.joined(separator: "."))
        }
    }

    /// An optional value is written as null; leaving its key out is still a missing key.
    func testOptionalValuesAreNullNotLeftOut() throws {
        let sample = try object()
        var nulls = changing(sample, at: ["assist", "lock"]) { $0["lock"] = NSNull() }
        nulls = changing(nulls, at: ["robot", "wrist", "tilt_centre_deg"]) { $0["tilt_centre_deg"] = NSNull() }
        nulls = changing(nulls, at: ["scene", "on_target_window_m"]) { $0["on_target_window_m"] = NSNull() }
        nulls = changing(nulls, at: ["assist", "views", "max_retargeted_move_s"]) {
            $0["max_retargeted_move_s"] = NSNull()
        }
        let profile = try decode(nulls)
        XCTAssertEqual(profile.wrist.tiltCentre, .measuredAfterReset)
        XCTAssertNil(profile.assist.lock)
        XCTAssertNil(profile.onTargetWindow)
        XCTAssertNil(profile.assist.views?.maxRetargetedMoveS)
        let noneAtAll = changing(sample, at: ["assist"]) {
            $0["assist"] = [
                "lock": NSNull(), "go_to": NSNull(), "guide": NSNull(), "explain": NSNull(),
                "views": NSNull(),
            ]
        }
        XCTAssertEqual(try decode(noneAtAll).assist, .none)
    }

    func testAVectorOfTheWrongLengthIsRefused() throws {
        let short = changing(try object(), at: ["scene", "base_in_world_m"]) { $0["base_in_world_m"] = [0, 0] }
        XCTAssertEqual(error(short), .wrongLength("scene.base_in_world_m", expected: 3, found: 2))
        let long = changing(try object(), at: ["scene", "grasp_tolerance_m"]) { $0["grasp_tolerance_m"] = [1, 2, 3] }
        XCTAssertEqual(error(long), .wrongLength("scene.grasp_tolerance_m", expected: 2, found: 3))
    }

    /// Text where a number goes, or a file that is not JSON, is refused with where it is.
    func testAValueOfTheWrongKindIsNamed() throws {
        let text = changing(try object(), at: ["scene", "target_size_m"]) { $0["target_size_m"] = "25 mm" }
        let data = try JSONSerialization.data(withJSONObject: text)
        XCTAssertThrowsError(try RobotProfile.load(json: data)) { error in
            XCTAssertEqual(error as? ProfileFormatError, .badValue("scene.target_size_m"))
            XCTAssertEqual("\(error)", "scene.target_size_m has a value of the wrong kind.")
        }
        XCTAssertThrowsError(try RobotProfile.load(json: Data("{ \"name\": ".utf8))) { error in
            XCTAssertEqual(error as? ProfileFormatError, .badValue(""))
        }
    }

    /// A section of the wrong kind, or an element of an array, is named by its path; an element's place is written in
    /// brackets after the key.
    func testASectionOrAnArrayElementOfTheWrongKindIsNamed() throws {
        let cases: [([String], Any, String)] = [
            (["robot"], 5, "robot"),
            (["assist", "guide"], "all", "assist.guide"),
            (["scene", "tool_offset"], [1, 2], "scene.tool_offset"),
            (["scene", "base_in_world_m"], ["a", 0, 0], "scene.base_in_world_m[0]"),
            (["scene", "workspace_max_m"], [0.1, -0.1, "top"], "scene.workspace_max_m[2]"),
        ]
        for (path, value, named) in cases {
            let wrong = changing(try object(), at: path) { $0[path.last!] = value }
            let data = try JSONSerialization.data(withJSONObject: wrong)
            XCTAssertThrowsError(try RobotProfile.load(json: data), named) { error in
                XCTAssertEqual(error as? ProfileFormatError, .badValue(named))
                XCTAssertEqual("\(error)", "\(named) has a value of the wrong kind.")
            }
        }
    }

    /// A key written twice in one object is refused with its path, at any level and however its name is escaped.
    func testARepeatedKeyIsRefusedByItsPath() throws {
        let cases = [
            ("\"profile_version\": 1,", "\"profile_version\": 1, \"profile_version\": 1,", "profile_version"),
            ("\"table_height_m\": 0.02,", "\"table_height_m\": 0.02, \"table_height_m\": 0.4,", "scene.table_height_m"),
            (
                "\"x_mm_per_cm\": 1,", "\"x_mm_per_cm\": 1, \"x_mm_per_cm\": 1,",
                "scene.tool_offset.error_bound.x_mm_per_cm"
            ),
            ("\"goal_size_m\": 0.06,", "\"goal_size_m\": 0.06, \"goal\\u005fsize_m\": 0.06,", "scene.goal_size_m"),
        ]
        for (once, twice, path) in cases {
            XCTAssertTrue(Self.sample.contains(once), once)
            let json = Data(Self.sample.replacingOccurrences(of: once, with: twice).utf8)
            XCTAssertThrowsError(try RobotProfile.load(json: json), path) { error in
                XCTAssertEqual(error as? ProfileFormatError, .repeatedKey(path))
                XCTAssertEqual("\(error)", "The profile has \(path) more than once; write each field once.")
            }
        }
    }

    /// An axis that is not one of the six signed axes is refused with its path and a sentence that says only quarter
    /// turns are supported.
    func testAnAxisThatIsNotAQuarterTurnIsRefused() throws {
        let paths: [[String]] = [
            ["robot", "directions", "forward"], ["robot", "directions", "left"], ["robot", "directions", "up"],
            ["scene", "base_axes_in_world", "x"], ["scene", "base_axes_in_world", "y"],
            ["scene", "base_axes_in_world", "z"],
        ]
        for path in paths {
            for text in ["x", "+w", "up", "+xy", "45", "-0", ""] {
                let wrong = changing(try object(), at: path) { $0[path.last!] = text }
                let named = path.joined(separator: ".")
                let refused = try XCTUnwrap(error(wrong), named)
                XCTAssertEqual(refused, .notAnAxis(named, found: text))
                XCTAssertEqual(
                    "\(refused)",
                    "\(named) is \"\(text)\", which is not an axis; write one of +x, -x, +y, -y, +z or -z. "
                        + "Only quarter turns are supported, so a direction at another angle cannot be given.")
            }
        }
    }

    func testAnAxisOfTheWrongKindIsNamed() throws {
        let wrong = changing(try object(), at: ["robot", "directions", "up"]) { $0["up"] = 3 }
        let data = try JSONSerialization.data(withJSONObject: wrong)
        XCTAssertThrowsError(try RobotProfile.load(json: data)) { error in
            XCTAssertEqual(error as? ProfileFormatError, .badValue("robot.directions.up"))
        }
        let signs = changing(try object(), at: ["server", "link_signs"]) { $0["link_signs"] = ["+", 1, 1] }
        let signsData = try JSONSerialization.data(withJSONObject: signs)
        XCTAssertThrowsError(try RobotProfile.load(json: signsData)) { error in
            XCTAssertEqual(error as? ProfileFormatError, .badValue("server.link_signs[0]"))
        }
    }

    func testTheLinkSignsNeedThreeNumbers() throws {
        let short = changing(try object(), at: ["server", "link_signs"]) { $0["link_signs"] = [1, -1] }
        XCTAssertEqual(error(short), .wrongLength("server.link_signs", expected: 3, found: 2))
    }

    /// A file whose directions make a mirror image, or whose world axes repeat, loads no further than the sentence.
    func testFramesThatMakeNoSenseAreRefusedWhenLoading() throws {
        let mirrored = changing(try object(), at: ["robot", "directions", "left"]) { $0["left"] = "+y" }
        XCTAssertThrowsError(try RobotProfile.load(json: JSONSerialization.data(withJSONObject: mirrored))) { error in
            XCTAssertEqual(
                "\(error)",
                "robot.directions: forward, left and up make a mirror image of the operator's view, not a turn of "
                    + "the base. Flip the sign of one of the three.")
        }
        let repeated = changing(try object(), at: ["scene", "base_axes_in_world", "y"]) { $0["y"] = "+y" }
        XCTAssertThrowsError(try RobotProfile.load(json: JSONSerialization.data(withJSONObject: repeated))) { error in
            XCTAssertEqual(
                "\(error)",
                "scene.base_axes_in_world: x, y and z must lie along three different world axes, one each; "
                    + "they are x +y, y +y, z -z.")
        }
    }

    /// A jaw unit that is neither of the two is refused with its path and the two that are allowed; a unit of the
    /// wrong kind is named like any value of the wrong kind.
    func testAJawUnitThatIsNotDegOrMmIsRefused() throws {
        for text in ["cm", "DEG", "degrees", ""] {
            let wrong = changing(try object(), at: ["robot", "gripper", "unit"]) { $0["unit"] = text }
            let refused = try XCTUnwrap(error(wrong), text)
            XCTAssertEqual(refused, .notAUnit("robot.gripper.unit", found: text))
            XCTAssertEqual(
                "\(refused)", "robot.gripper.unit is \"\(text)\", which is not a unit; write \"deg\" or \"mm\".")
        }
        let number = changing(try object(), at: ["robot", "gripper", "unit"]) { $0["unit"] = 3 }
        XCTAssertThrowsError(try RobotProfile.load(json: JSONSerialization.data(withJSONObject: number))) { error in
            XCTAssertEqual(error as? ProfileFormatError, .badValue("robot.gripper.unit"))
        }
    }

    /// Both units load, and the unit is what the profile says it is.
    func testBothJawUnitsLoad() throws {
        for unit in JawUnit.allCases {
            let file = changing(try object(), at: ["robot", "gripper", "unit"]) { $0["unit"] = unit.rawValue }
            XCTAssertEqual(try decode(file).gripper.unit, unit)
        }
    }

    func testAnotherVersionIsRefused() throws {
        let later = changing(try object(), at: ["profile_version"]) { $0["profile_version"] = 2 }
        XCTAssertEqual(error(later), .unsupportedVersion(2))
    }

    /// The version is read before the keys: a later version's file, with keys this format does not have or lacks,
    /// says that its version is not supported.
    func testAnotherVersionIsRefusedBeforeItsKeys() throws {
        var later = changing(try object(), at: ["profile_version"]) { $0["profile_version"] = 2 }
        later["camera"] = ["height_m": 0.5]
        later["robot"] = nil
        let refused = try XCTUnwrap(error(later))
        XCTAssertEqual(refused, .unsupportedVersion(2))
        XCTAssertEqual("\(refused)", "profile_version 2 is not supported; this app reads version 1.")
    }

    /// The "On target" window may be as narrow as the grasp tolerance, or wider, or absent.
    func testAnOnTargetWindowAsWideAsTheGraspToleranceIsValid() throws {
        var profile = try RobotProfile.load(json: Data(Self.sample.utf8))
        profile.onTargetWindow = profile.graspTolerance
        XCTAssertEqual(profile.validate(), [])
        profile.onTargetWindow = nil
        XCTAssertEqual(profile.validate(), [])
    }

    /// Each fault gives its own sentence naming the field, and `load` refuses the file with all of them.
    func testEachValidationFaultIsNamed() throws {
        let valid = try RobotProfile.load(json: Data(Self.sample.utf8))
        let cases: [(String, (inout RobotProfile) -> Void)] = [
            ("name must not be empty.", { $0.name = " " }),
            ("robot.wrist.roll_sign must be 1 or -1.", { $0.rollSign = 0.5 }),
            ("robot.wrist.tilt_sign must be 1 or -1.", { $0.tiltSign = 0 }),
            ("robot.wrist.roll_window_deg must be above zero.", { $0.wrist.rollWindowDeg = 0 }),
            ("robot.wrist.tilt_window_deg must be above zero.", { $0.wrist.tiltWindowDeg = -5 }),
            ("robot.wrist.roll_clamp_deg must be above zero.", { $0.wrist.rollClampDeg = 0 }),
            ("robot.wrist.tilt_clamp_deg must be above zero.", { $0.wrist.tiltClampDeg = -1 }),
            (
                "robot.wrist.roll_clamp_deg must not be above robot.wrist.roll_window_deg.",
                { $0.wrist.rollClampDeg = 91 }
            ),
            (
                "robot.wrist.tilt_clamp_deg must not be above robot.wrist.tilt_window_deg.",
                { $0.wrist.tiltClampDeg = 46 }
            ),
            ("robot.wrist.tilt_centre_deg must be a finite number, or null.", { $0.wrist.tiltCentre = .fixed(.nan) }),
            ("robot.wrist.turn_rate_deg_s must be above zero.", { $0.wrist.turnRateDegS = 0 }),
            ("robot.wrist.tilt_rate_deg_s must be above zero.", { $0.wrist.tiltRateDegS = -10 }),
            ("robot.wrist.lead.lead_deg must be zero or more.", { $0.wrist.lead.leadDeg = -1 }),
            ("robot.wrist.lead.rate_max_deg_s must be zero or more.", { $0.wrist.lead.rateMaxDegS = -1 }),
            ("robot.wrist.lead.memory_deg must be zero or more.", { $0.wrist.lead.memoryDeg = -0.5 }),
            ("robot.wrist.lead.fresh_state_ms must be above zero.", { $0.wrist.lead.freshStateMs = 0 }),
            (
                "robot.gripper.closed_reading and robot.gripper.open_reading must be different numbers.",
                { $0.gripper.openReading = 0 }
            ),
            (
                "robot.gripper.closed_reading and robot.gripper.open_reading must be different numbers.",
                { $0.gripper.closedReading = .nan }
            ),
            (
                "robot.gripper.closed_reading must be below robot.gripper.open_reading; a jaw whose reading falls "
                    + "as it opens is not supported.",
                {
                    $0.gripper.closedReading = 40; $0.gripper.openReading = 0
                }
            ),
            ("robot.gripper.valid_min must be below robot.gripper.valid_max.", { $0.gripper.validMax = 0 }),
            ("robot.gripper.valid_min must be below robot.gripper.valid_max.", { $0.gripper.validMin = 50 }),
            ("robot.gripper.valid_min must be below robot.gripper.valid_max.", { $0.gripper.validMax = .infinity }),
            (
                "robot.gripper.closed_reading must be inside the valid readings, robot.gripper.valid_min to valid_max.",
                { $0.gripper.validMin = 5 }
            ),
            (
                "robot.gripper.open_reading must be inside the valid readings, robot.gripper.valid_min to valid_max.",
                { $0.gripper.validMax = 30 }
            ),
            (
                "robot.gripper.open_reading must be inside the valid readings, robot.gripper.valid_min to valid_max.",
                { $0.gripper.openReading = .nan }
            ),
            // The two floors the jaw had before the readings were named: `open_deg` above zero and `empty_deg` zero
            // or more, now stated against the jaw's own shut reading and open reading.
            ("robot.gripper.empty_at must be at or above robot.gripper.closed_reading.", { $0.gripper.emptyAt = -1 }),
            (
                "robot.gripper.empty_at must be below robot.gripper.fully_open_at.",
                {
                    $0.gripper.fullyOpenAt = 0; $0.gripper.emptyAt = 0
                }
            ),
            (
                "robot.gripper.fully_open_at must be at or below robot.gripper.open_reading.",
                { $0.gripper.fullyOpenAt = 41 }
            ),
            (
                "robot.gripper.fully_open_at must be at or below robot.gripper.open_reading.",
                { $0.gripper.fullyOpenAt = .nan }
            ),
            ("robot.gripper.empty_at must be a finite number.", { $0.gripper.emptyAt = .infinity }),
            ("robot.gripper.fully_open_at must be a finite number.", { $0.gripper.fullyOpenAt = -.infinity }),
            ("robot.gripper.empty_at must be below robot.gripper.fully_open_at.", { $0.gripper.emptyAt = 39 }),
            ("robot.gripper.empty_at must be below robot.gripper.fully_open_at.", { $0.gripper.emptyAt = 40 }),
            ("scene.base_in_world_m must be finite numbers.", { $0.baseInWorld.x = .infinity }),
            (
                "robot.directions: forward, left and up make a mirror image of the operator's view, not a turn of "
                    + "the base. Flip the sign of one of the three.",
                { $0.frames.forward = $0.frames.forward.reversed }
            ),
            (
                "robot.directions: forward, left and up must lie along three different base axes, one each; "
                    + "they are forward +x, left +x, up -z.",
                { $0.frames.left = SignedAxis(.x, 1) }
            ),
            (
                "server.link_signs must each be 1 or -1; only a mirrored axis is supported.",
                { $0.frames.linkSigns.z = 0 }
            ),
            (
                "scene.base_axes_in_world is a mirror image, not a turn: the base's x cross y must be its z. "
                    + "Flip the sign of one of the three.",
                { $0.frames.worldTurn.z = $0.frames.worldTurn.z.reversed }
            ),
            (
                "scene.base_axes_in_world: x, y and z must lie along three different world axes, one each; "
                    + "they are x +y, y +y, z -z.",
                { $0.frames.worldTurn.y = SignedAxis(.y, 1) }
            ),
            ("scene.table_height_m must be finite numbers.", { $0.tableHeight = .nan }),
            (
                "scene.workspace_min_m must be below scene.workspace_max_m on every axis; it is not on y, z.",
                {
                    $0.workspaceMin.y = -0.1; $0.workspaceMin.z = 0.3
                }
            ),
            ("scene.workspace_min_m must be finite numbers.", { $0.workspaceMin.x = .nan }),
            ("scene.workspace_max_m must be finite numbers.", { $0.workspaceMax.x = .infinity }),
            ("scene.target_size_m must be above zero.", { $0.targetSize = 0 }),
            ("scene.goal_size_m must be above zero.", { $0.goalSize = -0.05 }),
            ("scene.grasp_tolerance_m across must be above zero.", { $0.graspTolerance.x = 0 }),
            ("scene.grasp_tolerance_m height must be above zero.", { $0.graspTolerance.y = -1 }),
            ("scene.on_target_window_m across must be above zero.", { $0.onTargetWindow?.x = 0 }),
            ("scene.on_target_window_m height must be above zero.", { $0.onTargetWindow?.y = 0 }),
            (
                "scene.on_target_window_m must not be narrower than scene.grasp_tolerance_m on either axis.",
                { $0.onTargetWindow?.x = 0.004 }
            ),
            (
                "scene.on_target_window_m must not be narrower than scene.grasp_tolerance_m on either axis.",
                { $0.onTargetWindow?.y = 0.006 }
            ),
            ("scene.tool_offset.offset_m must be finite numbers.", { $0.toolOffset.z = .nan }),
            ("scene.tool_offset.measured_at_m must be finite numbers.", { $0.offsetMeasuredAt.y = .infinity }),
            (
                "scene.tool_offset.measured_flex_deg and measured_roll_deg must be finite numbers.",
                { $0.offsetMeasuredFlexDeg = .nan }
            ),
            (
                "scene.tool_offset.error_bound.plus_y_mm_per_cm must be zero or more.",
                {
                    $0.estimateBound.plusYMmPerCm = -1
                }
            ),
            ("assist.lock.time_limit_s must be above zero.", { $0.assist.lock?.timeLimitS = 0 }),
            ("assist.go_to.travel_height_m must be above zero.", { $0.assist.goTo?.travelHeightM = 0 }),
            ("assist.go_to.speed_mps must be above zero.", { $0.assist.goTo?.speedMps = 0 }),
            ("assist.go_to.arrive_tolerance_m must be above zero.", { $0.assist.goTo?.arriveToleranceM = 0 }),
            ("assist.go_to.settle_s must be above zero.", { $0.assist.goTo?.settleS = 0 }),
            ("assist.go_to.time_factor must be above zero.", { $0.assist.goTo?.timeFactor = 0 }),
            ("assist.go_to.arm_data_timeout_s must be above zero.", { $0.assist.goTo?.armDataTimeoutS = .nan }),
            ("assist.go_to.correction_reach_m must be zero or more.", { $0.assist.goTo?.correctionReachM = -0.01 }),
            ("assist.go_to.allowance_s must be zero or more.", { $0.assist.goTo?.allowanceS = -1 }),
            ("assist.go_to.start_grace_s must be zero or more.", { $0.assist.goTo?.startGraceS = -1 }),
            ("assist.go_to.corrections must be zero or more.", { $0.assist.goTo?.corrections = -1 }),
            (
                "assist.views.behind_top_above_table_m must be above zero.",
                {
                    $0.assist.views?.behindTopAboveTableM = 0
                }
            ),
            ("assist.views.max_retargeted_move_s must be above zero.", { $0.assist.views?.maxRetargetedMoveS = 0 }),
            (
                "assist.views.behind_top_above_table_m must not be below assist.go_to.travel_height_m.",
                {
                    $0.assist.views?.behindTopAboveTableM = 0.03
                }
            ),
            ("assist.views needs assist.go_to; without it the views are unused.", { $0.assist.goTo = nil }),
            ("assist.explain is set, so assist.guide must be set too.", { $0.assist.guide = nil }),
        ]
        for (sentence, fault) in cases {
            var profile = valid
            fault(&profile)
            XCTAssertTrue(profile.validate().contains(sentence), "\(sentence)\ngot: \(profile.validate())")
            // JSON cannot carry a number that is not finite, so those faults are checked on the value only.
            guard let json = try? JSONEncoder().encode(profile) else { continue }
            XCTAssertThrowsError(try RobotProfile.load(json: json), sentence) { error in
                guard case .invalid(let faults)? = error as? ProfileFormatError else {
                    return XCTFail("\(error)")
                }
                XCTAssertTrue(faults.contains(sentence), sentence)
            }
        }
    }
}
