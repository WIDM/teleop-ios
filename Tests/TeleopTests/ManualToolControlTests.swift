import simd
import TeleopCore
import XCTest
@testable import Teleop

private final class ManualToolTransport: LinkTransport {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    var sent: [[String: Any]] = []
    var now: () -> Int = { 0 }
    func open() {}
    func close() {}
    func send(_ text: String) {
        sent.append(try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])
    }
    func receive(_ type: String, _ payload: [String: Any] = [:], serverTime: Int? = nil) {
        let envelope: [String: Any] = ["v": 1, "type": type, "ts": serverTime ?? now(), "seq": 0, "payload": payload]
        onText?(String(data: try! JSONSerialization.data(withJSONObject: envelope), encoding: .utf8)!)
    }
    func messages(_ type: String) -> [[String: Any]] { sent.filter { $0["type"] as? String == type } }
}

final class ManualToolControlTests: XCTestCase {
    /// Whether an event tells the operator that the server refused or ended a hold: the general words, or the words
    /// of a reason that has its own class.
    private static func tellsAServerRefusal(_ event: CueKey) -> Bool {
        if case .serverRefusal = event { return true }
        return event == .letGo(.lateRejection) || event == .refused(.serverRefused)
    }

    private var model: AppModel!
    private var wire: ManualToolTransport!
    private var clock = 10_000
    private var camera: simd_float4x4? = TestPose.portrait
    private var saved: [String: Any] = [:]
    private let keys = [AppModel.controlModeKey, AppModel.taskAidKey, AppModel.assistKey, AppModel.lockChoiceKey]

    override func setUp() {
        super.setUp()
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
    }
    override func tearDown() {
        model = nil
        for key in keys { UserDefaults.standard.set(saved[key], forKey: key) }
        super.tearDown()
    }

    private func bringUp(
        tool: Bool = true, mode: ControlMode = .screenTurns, aids: Bool = false, coordinated: Bool = false
    ) {
        clock = 10_000
        camera = TestPose.portrait
        UserDefaults.standard.set(false, forKey: AppModel.taskAidKey)
        wire = ManualToolTransport()
        wire.now = { [unowned self] in clock }
        model = AppModel(
            start: .p4, haptics: NoHaptics(), sounds: SpySounds(), speech: SpySpeech(),
            pose: { [unowned self] in camera }, liveLink: true,
            makeTransport: { [unowned self] _ in wire }, makeObserverTransport: { _ in ManualToolTransport() },
            nowMs: { [unowned self] in clock }, inputClock: { [unowned self] in Double(clock) / 1000 },
            assistOn: aids, lockChoice: .off)
        model.controlMode = mode
        model.session.state.setSmoothing(0)
        model.session.state.sensitivity = 1
        model.session.state.serverAddress = "127.0.0.1:8765"
        model.connect()
        var welcome: [String: Any] =
            tool ? ["control_points": ["link_origin", "tool"], "tool_calibration_id": "test-tool"] : [:]
        if coordinated { welcome["tool_motion_modes"] = ["coordinated_height"] }
        wire.receive("welcome", welcome)
        state()
        model.surfaceChanged(width: 375, height: 667, safeTop: 20, safeBottom: 0)
    }

    private func state(tool: [Double]? = [0.01, -0.17, 0.07], origin: [Double] = [0, -0.14, 0.16]) {
        var payload: [String: Any] = ["estop": false, "ik": "ok", "gripper": "open", "ee_pos": origin]
        if let tool { payload["tool_pos"] = tool }
        wire.receive("state", payload)
    }

    private func lastPayload(_ type: String) throws -> [String: Any] {
        try XCTUnwrap(wire.messages(type).last?["payload"] as? [String: Any])
    }

    func testCoordinatedHeightKeepsOneHoldBeyondFiveMillimetersWithAidsOnOrOff() throws {
        for aids in [false, true] {
            bringUp(aids: aids, coordinated: true)
            model.setPrecisionPanelOpen(true)
            model.buttonDown(.down)
            XCTAssertEqual(try lastPayload("pose_start")["tool_motion"] as? String, "coordinated_height")
            for index in 1...12 {
                clock += 100
                wire.receive(
                    "state",
                    [
                        "estop": false, "ik": "pose_tracking", "gripper": "open",
                        "ee_pos": [0, -0.14, 0.16], "tool_pos": [0.01, -0.17, 0.07 - Double(index) * 0.001],
                    ])
                model.controller.tick()
                model.link.tick()
            }
            let delta = try XCTUnwrap(try lastPayload("pose_update")["p_rel_m"] as? [Double])
            XCTAssertEqual(delta[0], 0)
            XCTAssertEqual(delta[1], 0)
            XCTAssertGreaterThan(delta[2], 0.005)
            XCTAssertLessThanOrEqual(delta[2], 0.0171)
            XCTAssertEqual(wire.messages("pose_start").count, 1)
            XCTAssertEqual(wire.messages("pose_stop").count, 0)
            model.buttonUp(.down)
            XCTAssertEqual(wire.messages("pose_stop").count, 1)
            let updates = wire.messages("pose_update").count
            clock += 100
            model.link.tick()
            XCTAssertEqual(wire.messages("pose_update").count, updates)
        }
    }

    func testCoordinatedHeightCanReverseAfterRefusalBeforeNewTrackingState() throws {
        bringUp(coordinated: true)
        model.setPrecisionPanelOpen(true)
        model.buttonDown(.down)
        let first = try XCTUnwrap(wire.messages("pose_start").last?["seq"] as? Int)
        wire.receive("ack", ["seq": first, "status": "rejected", "reason": "tool_no_converged_path"])
        model.buttonUp(.down)
        clock += 100
        wire.receive(
            "state",
            [
                "estop": false, "ik": "no_solution", "gripper": "open",
                "ee_pos": [0, -0.14, 0.16], "tool_pos": [0.01, -0.17, 0.07],
            ])
        model.buttonDown(.up)
        XCTAssertEqual(wire.messages("pose_start").count, 2)
        let stops = wire.messages("pose_stop").count
        clock += 100
        model.controller.tick()
        model.link.tick()
        XCTAssertTrue(model.session.state.armMoving)
        XCTAssertEqual(wire.messages("pose_stop").count, stops)
        let delta = try XCTUnwrap(try lastPayload("pose_update")["p_rel_m"] as? [Double])
        XCTAssertLessThan(delta[2], 0)
        let second = try XCTUnwrap(wire.messages("pose_start").last?["seq"] as? Int)
        wire.receive("ack", ["seq": second, "status": "rejected", "reason": "tool_no_converged_path"])
        let updates = wire.messages("pose_update").count
        clock += 100
        model.link.tick()
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertEqual(wire.messages("pose_update").count, updates)
    }

    func testCoordinatedHeightRejectsNoSolutionAfterTrackingBegins() {
        bringUp(coordinated: true)
        model.setPrecisionPanelOpen(true)
        wire.receive(
            "state",
            [
                "estop": false, "ik": "no_solution", "gripper": "open",
                "ee_pos": [0, -0.14, 0.16], "tool_pos": [0.01, -0.17, 0.07],
            ])
        model.buttonDown(.up)
        for activity in ["pose_tracking", "no_solution"] {
            clock += 100
            wire.receive(
                "state",
                [
                    "estop": false, "ik": activity, "gripper": "open",
                    "ee_pos": [0, -0.14, 0.16], "tool_pos": [0.01, -0.17, 0.07],
                ])
        }
        model.controller.tick()
        model.link.tick()
        XCTAssertEqual(wire.messages("pose_stop").count, 1)
        XCTAssertFalse(model.session.state.armMoving)
    }

    func testCoordinatedRefusalCueIsTruthfulOnceForEitherObserverAndAckOrder() throws {
        for observerFirst in [true, false] {
            bringUp(coordinated: true)
            model.setPrecisionPanelOpen(true)
            model.buttonDown(.up)
            let sequence = try XCTUnwrap(wire.messages("pose_start").last?["seq"] as? Int)
            clock += 100
            wire.receive(
                "state",
                [
                    "estop": false, "ik": "pose_tracking", "gripper": "open",
                    "ee_pos": [0, -0.14, 0.16], "tool_pos": [0.01, -0.17, 0.07],
                ])
            model.controller.tick()
            model.link.tick()
            let updates = wire.messages("pose_update").count
            func observerRefusal() {
                clock += 100
                model.link.stateArrived(
                    ServerState(
                        estop: false, gripper: .open,
                        activity: .other("no_solution"), endEffector: SIMD3(0, -0.14, 0.16),
                        toolPoint: SIMD3(0.01, -0.17, 0.07)), serverMs: clock, onControl: false)
                model.link.tick()
            }
            func rejectedAck() {
                wire.receive("ack", ["seq": sequence, "status": "rejected", "reason": "tool_no_converged_path"])
            }
            if observerFirst { observerRefusal(); rejectedAck() } else { rejectedAck(); observerRefusal() }
            XCTAssertFalse(model.session.state.armMoving)
            XCTAssertEqual(wire.messages("pose_update").count, updates)
            XCTAssertFalse(model.cueLog.contains { $0.event == .letGo(.noAnswer) })
            XCTAssertEqual(
                model.cueLog.filter {
                    Self.tellsAServerRefusal($0.event)
                }.count, 1)
            clock += 100
            model.link.tick()
            XCTAssertEqual(wire.messages("pose_update").count, updates)
            XCTAssertEqual(
                model.cueLog.filter {
                    Self.tellsAServerRefusal($0.event)
                }.count, 1)
        }
    }

    func testCoordinatedRecoveryGraceExpiresDespiteRefreshedNoSolutionState() {
        bringUp(coordinated: true)
        model.setPrecisionPanelOpen(true)
        func refusedState() {
            wire.receive(
                "state",
                [
                    "estop": false, "ik": "no_solution", "gripper": "open",
                    "ee_pos": [0, -0.14, 0.16], "tool_pos": [0.01, -0.17, 0.07],
                ])
        }
        refusedState()
        model.buttonDown(.up)
        for _ in 0..<4 {
            clock += 100
            refusedState()
            model.controller.tick()
            model.link.tick()
            XCTAssertTrue(model.session.state.armMoving)
        }
        let updates = wire.messages("pose_update").count
        clock += 1
        refusedState()
        model.controller.tick()
        model.link.tick()
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertTrue(model.cueLog.contains { $0.event == .letGo(.noAnswer) })
        XCTAssertEqual(wire.messages("pose_stop").count, 1)
        XCTAssertEqual(wire.messages("pose_update").count, updates)
    }

    func testCoordinatedMotionLogKeepsToolTargetsSeparateFromOriginMeasurement() throws {
        bringUp(coordinated: true)
        var logs: [String] = []
        model.link.onLog = { logs.append($0) }
        model.setPrecisionPanelOpen(true)
        model.buttonDown(.down)
        clock += 100
        model.controller.tick()
        model.link.tick()
        let motion = try XCTUnwrap(logs.last { $0.hasPrefix("motion source=") })
        XCTAssertTrue(motion.contains("sent_target_base=none"), motion)
        XCTAssertTrue(motion.contains("measured_base=[0.0000,-0.1400,0.1600]"), motion)
        XCTAssertTrue(motion.contains("tool_intent_base=["), motion)
        XCTAssertTrue(motion.contains("tool_applied_base=["), motion)
        XCTAssertTrue(motion.contains("tool_base=[0.0100,-0.1700,0.0700]"), motion)
    }

    func testCoordinatedHeightStopsOnStaleState() throws {
        bringUp(coordinated: true)
        model.setPrecisionPanelOpen(true)
        model.buttonDown(.down)
        clock += 1000
        model.controller.tick()
        model.link.tick()
        XCTAssertEqual(wire.messages("pose_stop").count, 1)
        XCTAssertFalse(model.session.state.armMoving)
    }

    /// A free move follows the hand, which turns and curves. The tool-point path holds each server hold to one
    /// straight line with a fixed wrist and refuses a turn, so a free move does not ask for it.
    func testAFreePhoneMoveDoesNotAskForTheToolPointAndStopsOnRelease() throws {
        for mode in [ControlMode.screenTurns, .keyTurns] {
            bringUp(mode: mode)
            XCTAssertFalse(model.operating.taskAid)
            XCTAssertFalse(model.voiceAxisSession.enabled)
            model.keyEvent(.upper, down: true)
            let start = try lastPayload("pose_start")
            XCTAssertNil(start["control_point"])
            XCTAssertNil(start["calibration_id"])
            var lowered = TestPose.portrait
            lowered.columns.3.y -= 0.005
            camera = lowered
            clock += 100
            model.link.tick()
            let delta = try XCTUnwrap(try lastPayload("pose_update")["p_rel_m"] as? [Double])
            XCTAssertEqual(delta[0], 0, accuracy: 1e-6)
            XCTAssertEqual(delta[1], 0, accuracy: 1e-6)
            XCTAssertEqual(delta[2], 0.005, accuracy: 1e-6)
            model.keyEvent(.upper, down: false)
            XCTAssertFalse(model.session.state.armMoving)
            XCTAssertEqual(wire.messages("pose_stop").count, 1)
            let sent = wire.messages("pose_update").count
            clock += 100
            model.link.tick()
            XCTAssertEqual(wire.messages("pose_update").count, sent)
        }
    }

    func testPrecisionButtonsUseToolWithoutTrackingAndStopOnRelease() throws {
        bringUp()
        camera = nil
        model.setPrecisionPanelOpen(true)
        model.buttonDown(.down)
        XCTAssertTrue(model.session.state.armMoving)
        XCTAssertEqual(try lastPayload("pose_start")["control_point"] as? String, "tool")
        clock += 100
        model.controller.tick()
        model.link.tick()
        let delta = try XCTUnwrap(try lastPayload("pose_update")["p_rel_m"] as? [Double])
        XCTAssertEqual(delta[0], 0, accuracy: 1e-6)
        XCTAssertEqual(delta[1], 0, accuracy: 1e-6)
        XCTAssertGreaterThan(delta[2], 0)
        model.buttonUp(.down)
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertEqual(wire.messages("pose_stop").count, 1)
    }

    /// The server's final answer to the newest start of `type`, then a state written after it.
    private func answerFinal(_ type: String, _ reason: String, ik: String = "ok", gripperDeg: Double? = nil) throws {
        let seq = try XCTUnwrap(wire.messages(type).last?["seq"] as? Int)
        wire.receive("ack", ["seq": seq, "status": "ok", "reason": reason])
        var payload: [String: Any] = [
            "estop": false, "ik": ik, "gripper": "closed", "ee_pos": [0, -0.14, 0.16], "tool_pos": [0.01, -0.17, 0.07],
        ]
        if let gripperDeg { payload["gripper_deg"] = gripperDeg }
        wire.receive("state", payload)
    }

    /// Closes the jaws on the cube: the server reports contact while the close is held, then the close is let go.
    private func grip() throws {
        model.buttonDown(.close)
        XCTAssertEqual(try lastPayload("gripper_jog_start")["action"] as? String, "close")
        clock += 100
        model.link.tick()
        wire.receive(
            "state",
            [
                "estop": false, "ik": "gripper_contact", "gripper": "closed", "gripper_deg": 1.5,
                "ee_pos": [0, -0.14, 0.16], "tool_pos": [0.01, -0.17, 0.07],
            ])
        model.buttonUp(.close)
        try answerFinal("gripper_jog_start", "gripper_jog_stopped", gripperDeg: 1.5)
    }

    /// A pad press, with the start it sent; nil when none went out.
    private func press(_ button: ButtonID) throws -> [String: Any]? {
        let starts = wire.messages("pose_start").count
        model.buttonDown(button)
        guard wire.messages("pose_start").count > starts else { return nil }
        return try lastPayload("pose_start")
    }

    private func release(_ button: ButtonID) throws {
        model.buttonUp(button)
        clock += 50
        try answerFinal("pose_start", "pose_stopped")
    }

    /// Carrying (the carry measurements of 2026-11-20: 0 of 10 on the tool point, 9 of 10 with the gripper link's
    /// path once the jaws hold the cube). After the server reports contact, every pad direction and up and down start on
    /// the gripper link's path as version 1.1.0 sent it: no control point, no calibration, no coordinated height, gain
    /// 1 and no smoothing, with the 8 cm lead and a resync every 1.5 s. Opening the jaws brings back the tool point.
    func testAHeldObjectIsCarriedOnTheGripperLinkPathUntilTheJawsOpen() throws {
        for aids in [false, true] {
            bringUp(aids: aids, coordinated: true)
            model.setPrecisionPanelOpen(true)
            try grip()
            XCTAssertTrue(model.link.holdingObject, "aids \(aids)")
            for button in [ButtonID.left, .forward, .up, .down] {
                let start = try XCTUnwrap(try press(button), "\(button), aids \(aids)")
                XCTAssertNil(start["control_point"], "\(button)")
                XCTAssertNil(start["calibration_id"], "\(button)")
                XCTAssertNil(start["tool_motion"], "\(button)")
                XCTAssertEqual(start["gain"] as? Double, 1, "\(button)")
                XCTAssertEqual(start["smoothing"] as? Double, 0, "\(button)")
                try release(button)
            }

            // Held for 1.4 s: the target runs more than 5 mm ahead and no resync has ended the server hold yet.
            _ = try XCTUnwrap(try press(.left))
            for _ in 0..<14 {
                clock += 100
                state()
                model.controller.tick()
                model.link.tick()
            }
            let delta = try XCTUnwrap(try lastPayload("pose_update")["p_rel_m"] as? [Double])
            let lead = simd_length(SIMD3(delta[0], delta[1], delta[2]))
            XCTAssertGreaterThan(lead, Double(TestProfiles.so101.motion.toolMaxLeadM))
            XCTAssertLessThanOrEqual(lead, Double(TestProfiles.so101.motion.maxLeadM) + 1e-6)
            XCTAssertEqual(wire.messages("pose_stop").count, 4, "no resync within 1.5 s, aids \(aids)")
            try release(.left)

            model.buttonDown(.open)
            XCTAssertTrue(model.link.holdingObject, "sent, not yet started, aids \(aids)")
            jawsOpening()
            XCTAssertFalse(model.link.holdingObject, "an open lets go, aids \(aids)")
            model.buttonUp(.open)
            try answerFinal("gripper_jog_start", "gripper_jog_stopped", gripperDeg: 60)
            XCTAssertEqual(try press(.left)?["control_point"] as? String, "tool", "aids \(aids)")
            try release(.left)
            XCTAssertEqual(try press(.down)?["tool_motion"] as? String, "coordinated_height", "aids \(aids)")
            try release(.down)
        }
    }

    /// A state the server wrote while it opens the jaws.
    private func jawsOpening() {
        clock += 50
        wire.receive(
            "state",
            [
                "estop": false, "ik": "gripper_jogging", "gripper": "open", "gripper_deg": 20,
                "ee_pos": [0, -0.14, 0.16], "tool_pos": [0.01, -0.17, 0.07],
            ])
    }

    /// An open the server refuses (another phone has control) leaves the jaws shut on the cube: the carry stays on the
    /// gripper link's path. An open the server runs lets go once a state shows it opening the jaws.
    func testARefusedOpenKeepsTheObjectHeld() throws {
        bringUp(coordinated: true)
        model.setPrecisionPanelOpen(true)
        try grip()
        model.buttonDown(.open)
        let open = try XCTUnwrap(wire.messages("gripper_jog_start").last?["seq"] as? Int)
        XCTAssertEqual(try lastPayload("gripper_jog_start")["action"] as? String, "open")
        wire.receive("ack", ["seq": open, "status": "rejected", "reason": "busy"])
        model.buttonUp(.open)
        clock += 100
        state()
        XCTAssertTrue(model.link.holdingObject, "the open was refused")
        let start = try XCTUnwrap(try press(.left))
        XCTAssertNil(start["control_point"])
        try release(.left)

        model.buttonDown(.open)
        XCTAssertTrue(model.link.holdingObject, "sent, not yet started")
        jawsOpening()
        XCTAssertFalse(model.link.holdingObject, "the server opens the jaws")
    }

    /// An empty close followed at once by a wrist turn: the turn's start waits for the close's final answer, goes out
    /// with it, and the state after the answer still tells the close was empty.
    func testAnEmptyCloseFollowedAtOnceByAWristTurnStillSaysEmpty() throws {
        for contact in [false, true] {
            bringUp()
            model.setPrecisionPanelOpen(true)
            model.buttonDown(.close)
            clock += 100
            model.link.tick()
            wire.receive(
                "state",
                [
                    "estop": false, "ik": "gripper_jogging", "gripper": "closed", "gripper_deg": contact ? 3 : 0.4,
                    "ee_pos": [0, -0.14, 0.16], "tool_pos": [0.01, -0.17, 0.07],
                ])
            model.buttonUp(.close)
            model.setPrecisionPanelOpen(false)
            model.send(.wristStart)
            let close = try XCTUnwrap(wire.messages("gripper_jog_start").last?["seq"] as? Int)
            wire.receive("ack", ["seq": close, "status": "ok", "reason": "gripper_jog_stopped"])
            XCTAssertEqual(wire.messages("orient_start").count, 1, "contact \(contact)")
            clock += 50
            wire.receive(
                "state",
                [
                    "estop": false, "ik": contact ? "gripper_contact" : "orienting", "gripper": "closed",
                    "gripper_deg": contact ? 1.5 : 0.4, "ee_pos": [0, -0.14, 0.16], "tool_pos": [0.01, -0.17, 0.07],
                ])
            XCTAssertEqual(
                model.cueLog.filter { $0.event == .limit(.empty) }.count, contact ? 0 : 1, "contact \(contact)")
            XCTAssertEqual(model.link.holdingObject, contact, "contact reported after the turn started")
            model.send(.wristEnd)
        }
    }

    /// After a hold that ended clamped the server keeps `pose_clamped` until the next command writes a new label. An up
    /// or down hold on coordinated height started then goes on through a tick before the first new state, and a clamp
    /// that arises during the hold, after its own tracking label, still ends it.
    func testALeftOverClampDoesNotEndACoordinatedHeightHold() throws {
        for button in [ButtonID.up, .down] {
            bringUp(coordinated: true)
            model.keyEvent(.upper, down: true)
            clock += 100
            model.link.tick()
            model.keyEvent(.upper, down: false)
            clock += 100
            try answerFinal("pose_start", "pose_stopped", ik: "pose_clamped")
            clock += 100
            failedState(activity: "pose_clamped")
            model.setPrecisionPanelOpen(true)
            XCTAssertEqual(try press(button)?["tool_motion"] as? String, "coordinated_height", "\(button)")
            let stops = wire.messages("pose_stop").count
            clock += 100
            model.controller.tick()
            model.link.tick()
            XCTAssertTrue(model.session.state.armMoving, "\(button)")
            XCTAssertEqual(wire.messages("pose_stop").count, stops, "\(button)")
            let delta = try XCTUnwrap(try lastPayload("pose_update")["p_rel_m"] as? [Double])
            if button == .up { XCTAssertLessThan(delta[2], 0) } else { XCTAssertGreaterThan(delta[2], 0) }

            clock += 100
            failedState(activity: "pose_tracking")
            model.controller.tick()
            model.link.tick()
            XCTAssertEqual(wire.messages("pose_stop").count, stops, "\(button)")
            clock += 100
            failedState(activity: "pose_clamped")
            model.controller.tick()
            model.link.tick()
            XCTAssertEqual(wire.messages("pose_stop").count, stops + 1, "a clamp during the hold, \(button)")
            XCTAssertFalse(model.session.state.armMoving, "\(button)")
        }
    }

    /// The wait for a new label is bounded: a hold that hears nothing but the left-over clamp ends as before.
    func testALeftOverClampIsWaitedOutOnlyBriefly() throws {
        bringUp(coordinated: true)
        model.keyEvent(.upper, down: true)
        clock += 100
        model.link.tick()
        model.keyEvent(.upper, down: false)
        clock += 100
        try answerFinal("pose_start", "pose_stopped", ik: "pose_clamped")
        clock += 100
        failedState(activity: "pose_clamped")
        model.setPrecisionPanelOpen(true)
        _ = try XCTUnwrap(try press(.up))
        let stops = wire.messages("pose_stop").count
        for _ in 0..<4 {
            clock += 100
            failedState(activity: "pose_clamped")
            model.controller.tick()
            model.link.tick()
            XCTAssertTrue(model.session.state.armMoving)
        }
        clock += 1
        failedState(activity: "pose_clamped")
        model.controller.tick()
        model.link.tick()
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertEqual(wire.messages("pose_stop").count, stops + 1)
    }

    /// The free phone move and the chosen axis keep their paths while an object is held.
    func testAHeldObjectLeavesThePhoneMovesOnTheirPaths() throws {
        bringUp()
        model.setPrecisionPanelOpen(true)
        try grip()
        model.setPrecisionPanelOpen(false)
        model.keyEvent(.upper, down: true)
        XCTAssertNil(try lastPayload("pose_start")["control_point"], "a free move")
        model.keyEvent(.upper, down: false)
        XCTAssertTrue(model.link.holdingObject)
    }

    /// A scene reset, a new episode and a reconnect each let go of the held object; a stop, the server's or the phone's
    /// own, keeps it.
    func testHoldingEndsWithAResetOrAReconnectAndOutlivesAStop() throws {
        let arm: [String: Any] = ["ik": "ok", "ee_pos": [0, -0.14, 0.16], "tool_pos": [0.01, -0.17, 0.07]]
        bringUp()
        model.setPrecisionPanelOpen(true)
        try grip()
        wire.receive("state", arm.merging(["estop": false, "episode": 1]) { $1 })
        XCTAssertTrue(model.link.holdingObject)
        wire.receive("state", arm.merging(["estop": false, "episode": 2]) { $1 })
        XCTAssertFalse(model.link.holdingObject, "a new episode")

        bringUp()
        model.setPrecisionPanelOpen(true)
        try grip()
        XCTAssertTrue(model.link.resetScene())
        let reset = try XCTUnwrap(wire.messages("reset_scene").last?["seq"] as? Int)
        wire.receive("ack", ["seq": reset, "status": "ok", "reason": "scene_reset"])
        XCTAssertFalse(model.link.holdingObject, "the server's answer to a reset")

        bringUp()
        model.setPrecisionPanelOpen(true)
        try grip()
        wire.receive("state", arm.merging(["estop": true]) { $1 })
        XCTAssertTrue(model.link.holdingObject, "a stop keeps what the jaws hold")

        bringUp()
        model.setPrecisionPanelOpen(true)
        try grip()
        model.link.estop()
        XCTAssertTrue(model.link.holdingObject, "the phone's own stop keeps it too")

        bringUp()
        model.setPrecisionPanelOpen(true)
        try grip()
        model.link.closeQuietly()
        XCTAssertFalse(model.link.holdingObject, "the connection closed")
    }

    /// The operator's log at 10:53:52: a free phone move ended clamped at the work area's edge, the server's label stayed
    /// `pose_clamped`, and ten pad presses were refused as busy although the arm had stopped. The hold that clamped has
    /// ended and been answered, so the pad starts.
    func testAPhoneMoveThatEndedClampedDoesNotBlockThePad() throws {
        bringUp()
        model.keyEvent(.upper, down: true)
        clock += 100
        model.link.tick()
        model.keyEvent(.upper, down: false)
        clock += 100
        try answerFinal("pose_start", "pose_stopped", ik: "pose_clamped")
        clock += 300
        failedState(activity: "pose_clamped")
        XCTAssertNil(model.link.padStartRefusal)
        XCTAssertEqual(model.link.manualTranslationStartRefusal, .busy, "only the pad is let through")
        XCTAssertFalse(
            model.link.startHold(PoseParams(gain: 1, smoothing: 0, toolCalibrationID: "test-tool"), axis: .leftRight),
            "a chosen-axis move by the phone still waits, as before")
        XCTAssertTrue(wire.messages("pose_start").count == 1)
        model.setPrecisionPanelOpen(true)
        XCTAssertEqual(try press(.left)?["control_point"] as? String, "tool")
        XCTAssertTrue(model.session.state.armMoving)
        model.buttonUp(.left)
    }

    /// Clamped while a hold of this phone still runs, or before the server has answered its stop, is still busy.
    func testAClampWhileAHoldRunsOrBeforeItsAnswerStillRefuses() throws {
        bringUp()
        model.keyEvent(.upper, down: true)
        failedState(activity: "pose_clamped")
        XCTAssertEqual(model.link.manualTranslationStartRefusal, .busy, "the hold runs")
        XCTAssertEqual(model.link.padStartRefusal, .busy, "the hold runs, for the pad too")
        model.keyEvent(.upper, down: false)
        failedState(activity: "pose_clamped")
        XCTAssertEqual(model.link.manualTranslationStartRefusal, .busy, "its stop is not answered")
        XCTAssertEqual(model.link.padStartRefusal, .busy, "its stop is not answered, for the pad too")
    }

    func testMissingToolMeasurementRefusesThePadRatherThanUsingOrigin() {
        bringUp()
        state(tool: nil)
        model.setPrecisionPanelOpen(true)
        model.buttonDown(.down)
        XCTAssertTrue(wire.messages("pose_start").isEmpty)
        XCTAssertFalse(model.session.state.armMoving)
        model.buttonUp(.down)
    }

    func testStaleToolMeasurementRefusesThePad() {
        bringUp()
        clock += FeedbackMonitor.freshStateMs + 1
        model.setPrecisionPanelOpen(true)
        model.buttonDown(.down)
        XCTAssertTrue(wire.messages("pose_start").isEmpty)
        XCTAssertFalse(model.session.state.armMoving)
        model.buttonUp(.down)
    }

    func testButtonsModeUsesCalibratedToolWithoutTracking() throws {
        bringUp(mode: .buttons)
        camera = nil
        model.buttonDown(.down)
        XCTAssertTrue(model.session.state.armMoving)
        XCTAssertEqual(try lastPayload("pose_start")["control_point"] as? String, "tool")
        model.buttonUp(.down)
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertEqual(wire.messages("pose_stop").count, 1)
    }

    private func failedState(activity: String = "no_solution", estop: Bool = false, busy: Bool = false) {
        wire.receive(
            "state",
            [
                "estop": estop, "ik": activity, "task_success": busy, "gripper": "open",
                "ee_pos": [0.0, -0.14, 0.16], "tool_pos": [0.01, -0.17, 0.07],
            ])
    }

    func testRejectedToolMoveAllowsFreshManualReverseAfterRelease() throws {
        bringUp()
        model.setPrecisionPanelOpen(true)
        model.buttonDown(.down)
        clock += 350
        model.link.tick()
        let sequence = try XCTUnwrap(wire.messages("pose_start").last?["seq"] as? Int)
        wire.receive("ack", ["seq": sequence, "status": "rejected", "reason": "tool_no_converged_path"])
        failedState()
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertTrue(model.link.isUp)
        XCTAssertNil(model.link.freshToolPointForStep)
        model.buttonUp(.down)
        model.buttonDown(.up)
        XCTAssertTrue(model.session.state.armMoving)
        XCTAssertEqual(wire.messages("pose_start").count, 2)
        clock += 100
        model.controller.tick()
        model.link.tick()
        let delta = try XCTUnwrap(try lastPayload("pose_update")["p_rel_m"] as? [Double])
        XCTAssertLessThan(delta[2], 0)
        model.buttonUp(.up)
        XCTAssertFalse(model.session.state.armMoving)
    }

    func testConnectedButStaleOrUnsafeToolStateExplainsReadinessInsteadOfNoLink() {
        for (activity, reason) in [
            ("no_solution", Refusal.noArmData), ("pose_tracking", .busy), ("resetting", .notReady),
            ("unrecognized", .notReady),
        ] {
            bringUp()
            model.setPrecisionPanelOpen(true)
            failedState(activity: activity)
            if activity == "no_solution" { clock += FeedbackMonitor.freshStateMs + 1 }
            model.buttonDown(.up)
            XCTAssertFalse(model.session.state.armMoving, activity)
            XCTAssertTrue(wire.messages("pose_start").isEmpty, activity)
            XCTAssertFalse(model.cueLog.contains { $0.event == .refused(.noLink) }, activity)
            XCTAssertTrue(model.cueLog.contains { $0.event == .refused(reason) }, activity)
            model.buttonUp(.up)
        }
    }

    func testPendingStopCannotBeBypassedByFailureLabel() {
        bringUp()
        model.setPrecisionPanelOpen(true)
        model.buttonDown(.down)
        model.buttonUp(.down)
        failedState()
        model.buttonDown(.up)
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertEqual(wire.messages("pose_start").count, 1)
        model.buttonUp(.up)
    }

    func testActuallyClosedLinkStillSaysNoLink() {
        bringUp()
        model.setPrecisionPanelOpen(true)
        model.link.closeQuietly()
        model.buttonDown(.up)
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertTrue(wire.messages("pose_start").isEmpty)
        XCTAssertTrue(model.cueLog.contains { $0.event == .refused(.noLink) })
        model.buttonUp(.up)
    }

    func testLegacyServerKeepsManualOriginControl() throws {
        bringUp(tool: false)
        model.keyEvent(.upper, down: true)
        XCTAssertTrue(model.session.state.armMoving)
        XCTAssertNil(try lastPayload("pose_start")["control_point"])
        XCTAssertNil(try lastPayload("pose_start")["calibration_id"])
        model.keyEvent(.upper, down: false)
    }

    func testJointLimitRefusalEndsManualHoldWithoutAutomaticRestart() throws {
        bringUp()
        model.keyEvent(.upper, down: true)
        let sequence = try XCTUnwrap(wire.messages("pose_start").last?["seq"] as? Int)
        wire.receive("ack", ["seq": sequence, "status": "rejected", "reason": "tool_joint_limit"])
        XCTAssertFalse(model.session.state.armMoving)
        for _ in 0..<5 {
            clock += 100
            state()
            model.link.tick()
        }
        XCTAssertEqual(wire.messages("pose_start").count, 1)
        XCTAssertTrue(wire.messages("pose_update").isEmpty)
        model.keyEvent(.upper, down: false)
    }

    private func beginResync(target: @escaping () -> SIMD3<Double>? = { SIMD3(0.1, 0, 0) }) throws -> Int {
        XCTAssertTrue(model.link.startButtonHold(useToolPoint: true, target))
        let sequence = try XCTUnwrap(wire.messages("pose_start").last?["seq"] as? Int)
        clock += 1600
        state()
        model.link.tick()
        XCTAssertEqual(wire.messages("pose_stop").count, 1)
        wire.receive("ack", ["seq": sequence, "status": "ok", "reason": "pose_stopped"])
        return sequence
    }

    func testResyncSubtractsMeasuredToolTravelInsteadOfLinkOriginTravel() throws {
        bringUp()
        var target = SIMD3(0.01, 0.0, 0.0)
        _ = try beginResync(target: { target })
        state(tool: [0.014, -0.17, 0.07], origin: [0.001, -0.14, 0.16])
        target.x = 0.007
        XCTAssertEqual(wire.messages("pose_start").count, 2)
        XCTAssertEqual(try lastPayload("pose_start")["control_point"] as? String, "tool")
        clock += 33
        model.link.tick()
        let delta = try XCTUnwrap(try lastPayload("pose_update")["p_rel_m"] as? [Double])
        XCTAssertEqual(delta[0], 0.003, accuracy: 1e-6)
        XCTAssertEqual(delta[1], 0, accuracy: 1e-6)
        XCTAssertEqual(delta[2], 0, accuracy: 1e-6)
        model.link.endHold()
    }

    func testToolFeedbackReportsFrozenPinchButNotProgressDespiteDifferentOriginMotion() {
        for aids in [false, true] {
            for progresses in [false, true] {
                bringUp(aids: aids)
                // A phone hold on the tool point, started at the link: a free move by the key no longer asks for it.
                XCTAssertTrue(
                    model.link.startHold(
                        PoseParams(gain: 1, smoothing: 0, toolCalibrationID: "test-tool", toolMotion: nil), axis: nil))
                var raised = TestPose.portrait
                raised.columns.3.y += 0.03
                camera = raised
                for elapsed in stride(from: 0, through: 1400, by: 200) {
                    clock = 10_100 + elapsed
                    let stopsBefore = wire.messages("pose_stop").count
                    model.link.tick()
                    let stopped = wire.messages("pose_stop").count > stopsBefore
                    if stopped,
                        let sequence = wire.messages("pose_start").last?["seq"] as? Int
                    {
                        wire.receive("ack", ["seq": sequence, "status": "ok", "reason": "pose_stopped"])
                    }
                    wire.receive(
                        "state",
                        [
                            "estop": false, "ik": stopped ? "ok" : "pose_tracking", "gripper": "open",
                            "ee_pos": [0.0, -0.14, 0.16 + (progresses ? 0 : Double(elapsed) * 0.00001)],
                            "tool_pos": [0.01, -0.17, 0.07 + (progresses ? Double(elapsed) * 0.00001 : 0)],
                        ])
                }
                let blocked = model.cueLog.filter { $0.event == .limit(.blocked) }.count
                XCTAssertEqual(blocked, progresses ? 0 : 1, "aids = \(aids), progresses = \(progresses)")
                XCTAssertNil(
                    model.link.commandedArm, "tool coordinates must not be interpreted as origin workspace commands")
                model.link.endHold()
                clock += 200
                model.link.tick()
                XCTAssertEqual(model.cueLog.filter { $0.event == .limit(.blocked) }.count, blocked)
            }
        }
    }

    func testToolCapRetainsTotalButtonDisplacementAcrossSegmentsAndReleaseStopsUpdates() throws {
        bringUp()
        var wanted = SIMD3(0.02, 0.0, 0.0)
        XCTAssertTrue(model.link.startButtonHold(useToolPoint: true, { wanted }))
        for segment in 1...3 {
            clock += 510
            state(tool: [0.01 + Double(segment - 1) * 0.005, -0.17, 0.07])
            model.link.tick()
            let delta = try XCTUnwrap(try lastPayload("pose_update")["p_rel_m"] as? [Double])
            XCTAssertEqual(delta[0], 0.005, accuracy: 1e-6)
            XCTAssertEqual(wire.messages("pose_stop").count, segment)
            let sequence = try XCTUnwrap(wire.messages("pose_start").last?["seq"] as? Int)
            wire.receive("ack", ["seq": sequence, "status": "ok", "reason": "pose_stopped"])
            state(tool: [0.01 + Double(segment) * 0.005, -0.17, 0.07])
            XCTAssertEqual(wire.messages("pose_start").count, segment + 1)
        }
        wanted.x = 0.018
        clock += 33
        model.link.tick()
        let remainder = try XCTUnwrap(try lastPayload("pose_update")["p_rel_m"] as? [Double])
        XCTAssertEqual(remainder[0], 0.003, accuracy: 1e-6)
        model.link.endHold()
        let updates = wire.messages("pose_update").count
        clock += 510
        state()
        model.link.tick()
        XCTAssertEqual(wire.messages("pose_update").count, updates)
        XCTAssertEqual(wire.messages("pose_start").count, 4)
    }

    func testReleaseDuringShortToolResyncCannotRestartAfterDelayedStopAnswer() throws {
        bringUp()
        XCTAssertTrue(model.link.startButtonHold(useToolPoint: true, { SIMD3(0.02, 0, 0) }))
        clock += 510
        state()
        model.link.tick()
        XCTAssertEqual(wire.messages("pose_stop").count, 1)
        let sequence = try XCTUnwrap(wire.messages("pose_start").last?["seq"] as? Int)
        model.link.endHold()
        wire.receive("ack", ["seq": sequence, "status": "ok", "reason": "pose_stopped"])
        state(tool: [0.015, -0.17, 0.07])
        clock += 100
        model.link.tick()
        XCTAssertEqual(wire.messages("pose_start").count, 1)
        XCTAssertEqual(wire.messages("pose_update").count, 1)
    }

    func testObserverNewerIdleBeforeControlPostStopIdleDoesNotAbortResync() throws {
        bringUp()
        _ = try beginResync()
        let newest = ServerState(
            activity: .ok, endEffector: SIMD3(0, -0.14, 0.16), toolPoint: SIMD3(0.014, -0.17, 0.07))
        model.link.stateArrived(newest, serverMs: clock + 2, onControl: false)
        XCTAssertFalse(model.link.armHeardAfterLastStop)
        state(tool: [0.014, -0.17, 0.07])
        XCTAssertTrue(model.link.armHeardAfterLastStop)
        XCTAssertEqual(wire.messages("pose_start").count, 2)
        XCTAssertFalse(model.cueLog.contains { $0.event == .letGo(.noAnswer) })
    }

    func testResyncWaitsForIdleToolStateAfterFinalAckInsteadOfClaimingNoAnswer() throws {
        bringUp()
        _ = try beginResync()
        failedState(activity: "pose_tracking")
        XCTAssertFalse(model.link.armHeardAfterLastStop)
        XCTAssertEqual(wire.messages("pose_start").count, 1)
        XCTAssertFalse(model.cueLog.contains { $0.event == .letGo(.noAnswer) })
        clock += 200
        state(tool: [0.014, -0.17, 0.07])
        XCTAssertEqual(wire.messages("pose_start").count, 2)
        XCTAssertFalse(model.cueLog.contains { $0.event == .letGo(.noAnswer) })
        model.link.endHold()
    }

    func testReleasedWhileWaitingForIdleToolSnapshotCannotResumeOnLateState() throws {
        bringUp()
        _ = try beginResync()
        failedState(activity: "pose_tracking")
        model.link.endHold()
        clock += 200
        state(tool: [0.014, -0.17, 0.07])
        model.link.tick()
        XCTAssertEqual(wire.messages("pose_start").count, 1)
        XCTAssertFalse(model.cueLog.contains { $0.event == .letGo(.noAnswer) })
    }

    func testIdleToolSnapshotPastResyncDeadlineCannotRestartEvenBeforeTimerTick() throws {
        bringUp()
        _ = try beginResync()
        clock += TestProfiles.so101.server.resync.timeoutMs + 1
        state(tool: [0.014, -0.17, 0.07])
        XCTAssertEqual(wire.messages("pose_start").count, 1)
        XCTAssertTrue(model.cueLog.contains { $0.event == .letGo(.noAnswer) })
        model.link.tick()
        state()
        XCTAssertEqual(wire.messages("pose_start").count, 1)
    }

    func testPreStopIdleSnapshotCannotConfirmOrResumeToolResync() throws {
        bringUp()
        _ = try beginResync()
        wire.receive(
            "state", ["ik": "ok", "ee_pos": [0.0, -0.14, 0.16], "tool_pos": [0.014, -0.17, 0.07]], serverTime: clock - 1
        )
        XCTAssertFalse(model.link.armHeardAfterLastStop)
        XCTAssertEqual(wire.messages("pose_start").count, 1)
        XCTAssertFalse(model.cueLog.contains { $0.event == .letGo(.noAnswer) })
        clock += 200
        state(tool: [0.014, -0.17, 0.07])
        XCTAssertEqual(wire.messages("pose_start").count, 2)
        model.link.endHold()
    }

    func testRefusedStopCompletionCannotResumeFromLaterIdleToolState() throws {
        bringUp()
        XCTAssertTrue(model.link.startButtonHold(useToolPoint: true, { SIMD3(0.02, 0, 0) }))
        let sequence = try XCTUnwrap(wire.messages("pose_start").last?["seq"] as? Int)
        clock += 510
        state()
        model.link.tick()
        wire.receive("ack", ["seq": sequence, "status": "rejected", "reason": "tool_no_converged_path"])
        state(tool: [0.014, -0.17, 0.07])
        clock += 200
        model.link.tick()
        XCTAssertEqual(wire.messages("pose_start").count, 1)
        model.link.endHold()
    }

    func testResyncRefusalEndsOnceWithoutNoAnswerForEitherAckOrder() throws {
        for stopFirst in [false, true] {
            bringUp()
            XCTAssertTrue(model.link.startButtonHold(useToolPoint: true, { SIMD3(0.02, 0, 0) }))
            let start = try XCTUnwrap(wire.messages("pose_start").last?["seq"] as? Int)
            clock += 510
            state()
            model.link.tick()
            let stop = try XCTUnwrap(wire.messages("pose_stop").last?["seq"] as? Int)
            let rejectedStart: [String: Any] = [
                "seq": start, "status": "rejected", "reason": "tool_measured_corridor",
            ]
            let rejectedStop: [String: Any] = [
                "seq": stop, "status": "rejected", "reason": "pose_not_active",
            ]
            wire.receive("ack", stopFirst ? rejectedStop : rejectedStart)
            wire.receive("ack", stopFirst ? rejectedStart : rejectedStop)
            let refusals = model.cueLog.filter { Self.tellsAServerRefusal($0.event) }.count
            XCTAssertEqual(refusals, 1, "stopFirst = \(stopFirst)")
            let updates = wire.messages("pose_update").count
            clock += TestProfiles.so101.server.resync.timeoutMs + 1
            state()
            model.link.tick()
            XCTAssertFalse(model.cueLog.contains { $0.event == .letGo(.noAnswer) })
            XCTAssertEqual(model.cueLog.filter { Self.tellsAServerRefusal($0.event) }.count, 1)
            XCTAssertEqual(wire.messages("pose_start").count, 1)
            XCTAssertEqual(wire.messages("pose_update").count, updates)
        }
    }

    func testPreviousHoldRefusalCannotEndCurrentResync() throws {
        bringUp(tool: false)
        XCTAssertTrue(model.link.startButtonHold { SIMD3(0.1, 0, 0) })
        let previous = try XCTUnwrap(wire.messages("pose_start").last?["seq"] as? Int)
        model.link.endHold()
        clock += TeleopLink.finishWaitMs + 1
        state()
        XCTAssertTrue(model.link.startButtonHold { SIMD3(0.1, 0, 0) })
        let current = try XCTUnwrap(wire.messages("pose_start").last?["seq"] as? Int)
        XCTAssertNotEqual(previous, current)
        clock += TestProfiles.so101.server.resync.afterMs + 1
        state()
        model.link.tick()
        XCTAssertEqual(wire.messages("pose_stop").count, 2)
        wire.receive("ack", ["seq": previous, "status": "rejected", "reason": "tool_measured_corridor"])
        XCTAssertFalse(model.cueLog.contains { $0.event == .letGo(.lateRejection) || $0.event == .letGo(.noAnswer) })
        wire.receive("ack", ["seq": current, "status": "ok", "reason": "pose_stopped"])
        state()
        XCTAssertEqual(wire.messages("pose_start").count, 3)
        model.link.endHold()
    }

    func testToolHoldCannotEnterResyncBehindPreviousUnansweredStop() throws {
        for phoneEntry in [false, true] {
            bringUp()
            XCTAssertTrue(model.link.startButtonHold(useToolPoint: true, { SIMD3(0.02, 0, 0) }))
            let previous = try XCTUnwrap(wire.messages("pose_start").last?["seq"] as? Int)
            model.link.endHold()
            clock += 1
            state()
            XCTAssertEqual(model.link.manualTranslationStartRefusal, .busy)
            if phoneEntry {
                XCTAssertFalse(model.link.startHold(PoseParams(gain: 1, smoothing: 0, toolCalibrationID: "test-tool")))
            } else {
                XCTAssertFalse(model.link.startButtonHold(useToolPoint: true, { SIMD3(0.02, 0, 0) }))
            }
            clock += TestProfiles.so101.server.resync.toolAfterMs + 1
            state()
            model.link.tick()
            XCTAssertEqual(wire.messages("pose_start").count, 1)
            XCTAssertEqual(wire.messages("pose_stop").count, 1)
            wire.receive("ack", ["seq": previous, "status": "rejected", "reason": "tool_measured_corridor"])
            XCTAssertFalse(
                model.cueLog.contains { $0.event == .letGo(.lateRejection) || $0.event == .letGo(.noAnswer) })
            XCTAssertEqual(wire.messages("pose_start").count, 1)
            clock += 1
            state()
            XCTAssertNil(model.link.manualTranslationStartRefusal)
            if phoneEntry {
                XCTAssertTrue(model.link.startHold(PoseParams(gain: 1, smoothing: 0, toolCalibrationID: "test-tool")))
            } else {
                XCTAssertTrue(model.link.startButtonHold(useToolPoint: true, { SIMD3(0.02, 0, 0) }))
            }
            XCTAssertEqual(wire.messages("pose_start").count, 2)
            wire.receive("ack", ["seq": previous, "status": "rejected", "reason": "tool_measured_corridor"])
            XCTAssertFalse(
                model.cueLog.contains { $0.event == .letGo(.lateRejection) || $0.event == .letGo(.noAnswer) })
            model.link.endHold()
        }
    }

    func testReleasedResyncDoesNotReportLateServerRefusal() throws {
        bringUp()
        XCTAssertTrue(model.link.startButtonHold(useToolPoint: true, { SIMD3(0.02, 0, 0) }))
        let start = try XCTUnwrap(wire.messages("pose_start").last?["seq"] as? Int)
        clock += 510
        state()
        model.link.tick()
        model.link.endHold()
        wire.receive("ack", ["seq": start, "status": "rejected", "reason": "tool_measured_corridor"])
        clock += TestProfiles.so101.server.resync.timeoutMs + 1
        state()
        model.link.tick()
        XCTAssertFalse(model.cueLog.contains { $0.event == .letGo(.lateRejection) || $0.event == .letGo(.noAnswer) })
        XCTAssertEqual(wire.messages("pose_start").count, 1)
    }

    func testResyncWithMissingToolStateWaitsUntilDeadlineThenCannotRestart() throws {
        bringUp()
        _ = try beginResync()
        state(tool: nil)
        XCTAssertEqual(wire.messages("pose_start").count, 1)
        let updates = wire.messages("pose_update").count
        XCTAssertFalse(model.cueLog.contains { $0.event == .letGo(.noAnswer) })
        clock += TestProfiles.so101.server.resync.timeoutMs + 1
        model.link.tick()
        state()
        XCTAssertEqual(wire.messages("pose_start").count, 1)
        XCTAssertEqual(wire.messages("pose_update").count, updates)
        XCTAssertTrue(model.cueLog.contains { $0.event == .letGo(.noAnswer) })
    }

    // A free phone move: the upper key with no axis chosen, following the hand on the gripper link's path.

    func testAFreePhoneMoveIsRefusedByABusyServerButNotByAnActivityLabelOrAStaleStop() {
        let cases: [(String, [String: Any], Bool)] = [
            // A state can lag a release the server has answered: the press goes out, and a server still stopped
            // refuses it itself.
            ("a state still saying stopped", ["estop": true], true),
            ("success shown", ["task_success": true], false),
            ("resetting", ["ik": "resetting"], false),
            ("clamped", ["ik": "pose_clamped"], true),
            ("no solution", ["ik": "no_solution"], true),
            ("tracking", ["ik": "pose_tracking"], true),
            ("turn clamped", ["ik": "orient_clamped"], true),
            ("contact", ["ik": "gripper_contact"], true),
            ("unknown label", ["ik": "unrecognized"], true),
        ]
        for (name, change, starts) in cases {
            bringUp()
            var payload: [String: Any] = [
                "estop": false, "ik": "ok", "gripper": "open", "ee_pos": [0.0, -0.14, 0.16],
                "tool_pos": [0.01, -0.17, 0.07],
            ]
            payload.merge(change) { $1 }
            wire.receive("state", payload)
            XCTAssertEqual(model.link.startHold(PoseParams(gain: 1, smoothing: 0)), starts, name)
            XCTAssertEqual(wire.messages("pose_start").count, starts ? 1 : 0, name)
            model.link.endHold()
        }
    }

    /// Lowers the phone 1 cm every 100 ms during a free phone move until the arm has been held at the lead cap long
    /// enough for a resync, then answers the resync's stop.
    private func freePhoneMoveIntoResync() throws {
        model.keyEvent(.upper, down: true)
        let sequence = try XCTUnwrap(wire.messages("pose_start").last?["seq"] as? Int)
        XCTAssertNil(try lastPayload("pose_start")["control_point"])
        var lowered = TestPose.portrait
        for _ in 0..<16 {
            lowered.columns.3.y -= 0.01
            camera = lowered
            clock += 100
            model.link.tick()
        }
        XCTAssertTrue(model.session.state.armMoving)
        XCTAssertEqual(wire.messages("pose_stop").count, 1, "the resync's stop")
        wire.receive("ack", ["seq": sequence, "status": "ok", "reason": "pose_stopped"])
    }

    func testAFreePhoneResyncWaitsForAnArmPositionNewerThanItsStop() throws {
        bringUp()
        try freePhoneMoveIntoResync()
        wire.receive(
            "state", ["estop": false, "ik": "ok", "gripper": "open", "ee_pos": [0.0, -0.14, 0.13]],
            serverTime: clock - 1)
        XCTAssertEqual(wire.messages("pose_start").count, 1, "a state the server wrote before the stop")
        clock += 10
        wire.receive("state", ["estop": false, "ik": "ok", "gripper": "open"])
        XCTAssertEqual(wire.messages("pose_start").count, 1, "a state without an arm position")
        XCTAssertTrue(model.session.state.armMoving)
        clock += 10
        wire.receive("state", ["estop": false, "ik": "pose_clamped", "gripper": "open", "ee_pos": [0.0, -0.14, 0.12]])
        XCTAssertEqual(wire.messages("pose_start").count, 2, "a clamp label left by the stopped hold does not wait")
        XCTAssertNil(try lastPayload("pose_start")["control_point"])
        XCTAssertTrue(model.session.state.armMoving)
        XCTAssertFalse(model.cueLog.contains { $0.event == .letGo(.noAnswer) })
        model.keyEvent(.upper, down: false)
    }
}
