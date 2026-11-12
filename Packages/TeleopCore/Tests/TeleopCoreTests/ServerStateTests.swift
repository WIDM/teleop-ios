import XCTest
@testable import TeleopCore

final class ServerStateTests: XCTestCase {
    private func parse(_ json: String) -> ServerState {
        ServerState(payload: try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])
    }

    func testEveryStateFieldTheAppUsesIsRead() {
        let state = parse("""
        {"estop": false, "gripper": "close", "ik": "gripper_contact", "ee_pos": [0.02, -0.14, 0.16],
         "task_success": false, "episode": 3, "rec": "capturing", "rec_saved": 12, "rec_discarded": 2,
         "rec_samples": 45, "rec_session": "s-1", "rec_mode": "phone-a",
         "wrist_flex_deg": 40.24, "wrist_roll_deg": 90, "gripper_deg": 8.5}
        """)
        XCTAssertEqual(state.gripper, .closed)
        XCTAssertEqual(state.activity, .gripperContact)
        XCTAssertEqual(state.endEffector, SIMD3(0.02, -0.14, 0.16))
        XCTAssertEqual(state.episode, 3)
        XCTAssertEqual(state.recorder, RecorderStatus(label: .capturing, saved: 12, discarded: 2, samples: 45, session: "s-1", mode: "phone-a"))
        XCTAssertEqual(state.wristFlexDeg, 40.24)
        XCTAssertEqual(state.wristRollDeg, 90)
        XCTAssertEqual(state.gripperDeg, 8.5)
    }

    /// A server without the key is an unknown server, never one without a recorder.
    func testNoRecKeyMeansTheRecorderIsUnknown() {
        let state = parse(#"{"estop": false, "rec_saved": 4}"#)
        XCTAssertNil(state.recorder)
        XCTAssertNil(state.wristRollDeg)
        XCTAssertEqual(parse(#"{"rec": "none"}"#).recorder?.label, RecorderLabel.none)
        XCTAssertEqual(parse(#"{"rec": "none"}"#).recorder?.records, false)
        XCTAssertNil(parse(#"{"rec": "paused"}"#).recorder, "an unknown label is not guessed at")
    }

    func testWrongTypesCountAsMissing() {
        let state = parse(#"{"estop": false, "gripper_deg": true, "episode": "3", "ee_pos": [1, 2]}"#)
        XCTAssertNil(state.gripperDeg)
        XCTAssertNil(state.episode)
        XCTAssertNil(state.endEffector)
    }

    /// A count too large for an Int must not crash the app.
    func testANumberTooLargeForACountIsMissing() {
        let state = parse(#"{"episode": 1e300, "rec": "armed", "rec_saved": -1e30, "rec_discarded": 2.9}"#)
        XCTAssertNil(state.episode)
        XCTAssertEqual(state.recorder?.saved, 0)
        XCTAssertEqual(state.recorder?.discarded, 2)
    }

    func testEveryActivityLabelTheAppActsOn() {
        let labels: [String: ServerActivity] = [
            "pose_tracking": .poseTracking, "pose_clamped": .poseClamped, "orienting": .orienting,
            "orient_clamped": .orientClamped, "gripper_jogging": .gripperJogging, "gripper_contact": .gripperContact,
            "ok": .ok, "stopped": .stopped, "task_success": .taskSuccess, "resetting": .resetting,
        ]
        for (label, activity) in labels { XCTAssertEqual(ServerActivity(label), activity, label) }
        XCTAssertEqual(ServerActivity("no_solution"), .other("no_solution"))
    }
}
