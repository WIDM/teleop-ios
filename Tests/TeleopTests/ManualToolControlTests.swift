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
            assistOn: aids, lockChoice: .off, voiceActionsPrototype: false)
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
                    $0.event == .letGo(.lateRejection) || $0.event == .refused(.serverRefused)
                }.count, 1)
            clock += 100
            model.link.tick()
            XCTAssertEqual(wire.messages("pose_update").count, updates)
            XCTAssertEqual(
                model.cueLog.filter {
                    $0.event == .letGo(.lateRejection) || $0.event == .refused(.serverRefused)
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

    func testPhoneTranslationUsesCalibratedToolWithoutVoiceOrAidAndStopsOnRelease() throws {
        for mode in [ControlMode.screenTurns, .keyTurns] {
            bringUp(mode: mode)
            XCTAssertFalse(model.operating.taskAid)
            XCTAssertFalse(model.voiceAxisSession.enabled)
            model.keyEvent(.upper, down: true)
            let start = try lastPayload("pose_start")
            XCTAssertEqual(start["control_point"] as? String, "tool")
            XCTAssertEqual(start["calibration_id"] as? String, "test-tool")
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

    func testMissingToolMeasurementRefusesManualPhoneAndPadRatherThanUsingOrigin() {
        bringUp()
        state(tool: nil)
        model.keyEvent(.upper, down: true)
        XCTAssertTrue(wire.messages("pose_start").isEmpty)
        XCTAssertFalse(model.session.state.armMoving)
        model.keyEvent(.upper, down: false)
        model.setPrecisionPanelOpen(true)
        model.buttonDown(.down)
        XCTAssertTrue(wire.messages("pose_start").isEmpty)
        XCTAssertFalse(model.session.state.armMoving)
        model.buttonUp(.down)
    }

    func testStaleToolMeasurementRefusesManualPhoneAndPad() {
        bringUp()
        clock += FeedbackMonitor.freshStateMs + 1
        model.keyEvent(.upper, down: true)
        XCTAssertTrue(wire.messages("pose_start").isEmpty)
        XCTAssertFalse(model.session.state.armMoving)
        model.keyEvent(.upper, down: false)
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

    func testRejectedToolMoveAllowsFreshManualReverseAfterReleaseButNotVoice() throws {
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
        XCTAssertNil(model.link.voiceMotionStartStamp)
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
                model.keyEvent(.upper, down: true)
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
                model.keyEvent(.upper, down: false)
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
        clock += LiveLinkController.resyncTimeoutMs + 1
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
            let refusals = model.cueLog.filter { $0.event == .letGo(.lateRejection) }.count
            XCTAssertEqual(refusals, 1, "stopFirst = \(stopFirst)")
            let updates = wire.messages("pose_update").count
            clock += LiveLinkController.resyncTimeoutMs + 1
            state()
            model.link.tick()
            XCTAssertFalse(model.cueLog.contains { $0.event == .letGo(.noAnswer) })
            XCTAssertEqual(model.cueLog.filter { $0.event == .letGo(.lateRejection) }.count, 1)
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
        clock += LiveLinkController.resyncAfterMs + 1
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
            clock += LiveLinkController.toolResyncAfterMs + 1
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
        clock += LiveLinkController.resyncTimeoutMs + 1
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
        clock += LiveLinkController.resyncTimeoutMs + 1
        model.link.tick()
        state()
        XCTAssertEqual(wire.messages("pose_start").count, 1)
        XCTAssertEqual(wire.messages("pose_update").count, updates)
        XCTAssertTrue(model.cueLog.contains { $0.event == .letGo(.noAnswer) })
    }
}
