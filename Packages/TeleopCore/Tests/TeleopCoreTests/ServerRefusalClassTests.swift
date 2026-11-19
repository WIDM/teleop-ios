import Foundation
import XCTest
@testable import TeleopCore

/// A server's refusal or ending of a manual arm hold is told by what the operator can do about it: touching something,
/// a joint at its limit, or a path the arm cannot take. Every other reason keeps the general refusal words.
final class ServerRefusalClassTests: XCTestCase {
    /// Every reason a server gives for refusing or ending a manual hold, with the class it is told by.
    private static let reasons: [String: ServerRefusalClass] = [
        "tool_measured_corridor": .contact,
        "tool_wrist_unsettled": .contact,
        "tool_wrist_changed": .contact,
        "tool_roll_changed": .contact,
        "tool_orientation_changed": .contact,
        "tool_joint_step": .contact,
        "tool_gravity_offset_unsettled": .contact,
        "tool_joint_limit": .jointLimit,
        "tool_actuator_joint_limit": .jointLimit,
        "tool_no_converged_path": .reach,
        "tool_path_corridor": .reach,
        "tool_origin_workspace": .reach,
        "tool_target_lead": .other,
        "tool_gripper_change_during_translation": .other,
        "tool_height_only": .other,
        "tool_stale_state": .other,
        "tool_hold_ended": .other,
        "tool_calibration_mismatch": .other,
        "tool_calibration_state_mismatch": .other,
        "tool_orientation_calibration_mismatch": .other,
        "tool_invalid_rotation": .other,
        "tool_jacobian_mismatch": .other,
        "tool_invalid_step": .other,
        "tool_invalid_workspace": .other,
        "tool_control_unavailable": .other,
        "tool_motion_unavailable": .other,
        "tool_gravity_unavailable": .other,
        "tool_invalid_joint_stiffness": .other,
        "tool_nonfinite_state": .other,
        "tool_nonfinite_or_invalid_shape": .other,
        "pose_tracking_safety_stop": .other,
        "pose_nonfinite_ik": .other,
        "pose_wrist_invalid_input": .other,
        "pose_wrist_nonfinite_state": .other,
        "pose_watchdog_timeout": .other,
        "busy": .other,
        "sim_not_ready": .other,
        "estop_active": .other,
        "estop": .other,
        "study_transition": .other,
        "mode_updated": .other,
        "sim_result_timeout": .other,
        "control_connection_lost": .other,
        "expired_before_execution": .other,
        "invalid_rate_hz": .other,
        "invalid_payload": .other,
        "no_solution": .other,
    ]

    private static let actionable: [ServerRefusalClass: SpeechKey] = [
        .contact: .refusedContact, .jointLimit: .refusedJointLimit, .reach: .refusedReach,
    ]

    func testEveryKnownReasonHasItsClass() {
        for (reason, refusalClass) in Self.reasons {
            XCTAssertEqual(ServerRefusalClass(reason: reason), refusalClass, reason)
        }
        XCTAssertEqual(
            Set(Self.reasons.values), Set(ServerRefusalClass.allCases), "every class is reached by some reason")
    }

    func testAnUnknownReasonKeepsTheGeneralWords() {
        for reason in ["", "tool_something_new", "TOOL_JOINT_LIMIT", "tool_joint_limit ", "joint_limit"] {
            XCTAssertEqual(ServerRefusalClass(reason: reason), .other, "'\(reason)'")
        }
    }

    // MARK: The monitor

    private func monitor() -> FeedbackMonitor {
        FeedbackMonitor(limits: GripperLimits(openDeg: 97, emptyDeg: 2))
    }

    func testARefusedStartIsToldByItsClass() {
        for (reason, refusalClass) in Self.reasons where refusalClass != .other {
            var monitor = monitor()
            monitor.startSent(.pose, restart: false, at: 0)
            XCTAssertEqual(
                monitor.startRefused(reason: reason, at: 20), [.serverRefusal(refusalClass, accepted: false)], reason)
            XCTAssertNil(monitor.engagedHold, "the refusal still ends the hold: \(reason)")
            XCTAssertEqual(monitor.tick(at: 1000), [], "no GO after a refusal: \(reason)")
        }
    }

    func testAHoldTheServerEndsLaterIsToldByItsClass() {
        for (reason, refusalClass) in Self.reasons where refusalClass != .other {
            var monitor = monitor()
            monitor.startSent(.pose, restart: false, at: 0)
            XCTAssertEqual(monitor.tick(at: 300), [.holdLive(hold: 1)])
            XCTAssertEqual(
                monitor.startRefused(reason: reason, at: 900), [.serverRefusal(refusalClass, accepted: true)], reason)
            XCTAssertNil(monitor.engagedHold, "the ending still ends the hold: \(reason)")
        }
    }

    func testAResyncRestartRefusedIsToldByItsClass() {
        var monitor = monitor()
        monitor.startSent(.pose, restart: false, at: 0)
        _ = monitor.tick(at: 300)
        monitor.resyncBegan()
        monitor.startSent(.pose, restart: true, at: 1000)
        XCTAssertEqual(
            monitor.startRefused(reason: "tool_measured_corridor", at: 1020), [.serverRefusal(.contact, accepted: true)]
        )
        XCTAssertNil(monitor.engagedHold)
    }

    func testOtherReasonsKeepTodaysEvents() {
        var before = monitor()
        before.startSent(.pose, restart: false, at: 0)
        XCTAssertEqual(before.startRefused(reason: "tool_target_lead", at: 20), [.refused(.serverRefused)])
        var after = monitor()
        after.startSent(.pose, restart: false, at: 0)
        _ = after.tick(at: 300)
        XCTAssertEqual(after.startRefused(reason: "tool_stale_state", at: 900), [.letGo(.lateRejection)])
        var watchdog = monitor()
        watchdog.startSent(.pose, restart: false, at: 0)
        _ = watchdog.tick(at: 300)
        XCTAssertEqual(watchdog.startRefused(reason: "pose_watchdog_timeout", at: 900), [.letGo(.watchdog)])
    }

    // MARK: The words

    func testEachClassSaysWhatToDo() {
        for (refusalClass, key) in Self.actionable {
            let start = CueTable.row(for: .serverRefusal(refusalClass, accepted: false))
            XCTAssertEqual(start.haptic, .no, "\(refusalClass): a refused start is a NO")
            XCTAssertEqual(start.speech, [key])
            XCTAssertEqual(start.level, .p2, "queued, never dropped behind other speech")
            let ended = CueTable.row(for: .serverRefusal(refusalClass, accepted: true))
            XCTAssertEqual(ended.haptic, .letGo, "\(refusalClass): an ended hold is a LET GO")
            XCTAssertEqual(ended.speech, [key])
            XCTAssertEqual(ended.level, .p2, "queued, never dropped behind other speech")
            XCTAssertEqual(DriveCue(server: refusalClass), .endedByServer(refusalClass))
            let drive = CueTable.row(for: .drive(DriveCue(server: refusalClass)))
            XCTAssertEqual(drive.speech, [.driveStoppedHere, key], "\(refusalClass): \"Stopped here.\" first")
            XCTAssertEqual(drive.haptic, .letGo)
            XCTAssertEqual(drive.level, .p2)
        }
    }

    func testTheGeneralClassSaysTodaysWords() {
        XCTAssertEqual(
            CueTable.row(for: .serverRefusal(.other, accepted: false)).speech,
            CueTable.row(for: .refused(.serverRefused)).speech)
        XCTAssertEqual(
            CueTable.row(for: .serverRefusal(.other, accepted: false)).haptic,
            CueTable.row(for: .refused(.serverRefused)).haptic)
        XCTAssertEqual(
            CueTable.row(for: .serverRefusal(.other, accepted: true)).speech,
            CueTable.row(for: .letGo(.lateRejection)).speech)
        XCTAssertEqual(
            CueTable.row(for: .serverRefusal(.other, accepted: true)).haptic,
            CueTable.row(for: .letGo(.lateRejection)).haptic)
        XCTAssertEqual(DriveCue(server: .other), .ended(.serverRefused))
        XCTAssertEqual(CueTable.row(for: .drive(.ended(.serverRefused))).speech, [.driveStoppedHere, .refusedMove])
        let general = CueTable.row(for: .drive(.endedByServer(.other)))
        let today = CueTable.row(for: .drive(.ended(.serverRefused)))
        XCTAssertEqual(general.speech, today.speech)
        XCTAssertEqual(general.haptic, today.haptic)
        XCTAssertEqual(general.level, today.level)
    }

    func testThePhrasesInBothLanguages() throws {
        let catalog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Resources/Speech.xcstrings")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: [String: Any]])
        func text(_ key: SpeechKey, _ language: String) -> String? {
            let localizations = strings[key.rawValue]?["localizations"] as? [String: [String: [String: String]]]
            return localizations?[language]?["stringUnit"]?["value"]
        }
        XCTAssertEqual(text(.refusedContact, "en"), "Touching something. Open the gripper or lift.")
        XCTAssertEqual(text(.refusedContact, "zh-Hant"), "碰到東西了。打開夾爪或抬高再試。")
        XCTAssertEqual(text(.refusedJointLimit, "en"), "Arm at its limit. Move the other way.")
        XCTAssertEqual(text(.refusedJointLimit, "zh-Hant"), "手臂彎到底了。請往反方向移。")
        XCTAssertEqual(text(.refusedReach, "en"), "Can't reach that way. Back off a little.")
        XCTAssertEqual(text(.refusedReach, "zh-Hant"), "這個方向到不了。請退回一點。")
        for key in Self.actionable.values {
            let words = try XCTUnwrap(text(key, "en")).split(separator: " ")
            XCTAssertLessThanOrEqual(words.count, 9, "\(key): short enough to hear during a hold")
        }
    }
}
