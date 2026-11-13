import simd
import TeleopCore
import XCTest
@testable import Teleop

private final class WireTransport: LinkTransport {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    var sent: [[String: Any]] = []

    func open() {}
    func close() {}
    func send(_ text: String) {
        sent.append(try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])
    }

    var types: [String] { sent.map { $0["type"] as! String } }

    func server(_ type: String, seq: Int = 0, _ payload: [String: Any] = [:]) {
        let message: [String: Any] = ["v": 1, "type": type, "ts": 0, "seq": seq, "payload": payload]
        onText?(String(data: try! JSONSerialization.data(withJSONObject: message), encoding: .utf8)!)
    }
}

/// The input rules' commands on the wire, on a test clock: the wrist hold's stream and its lead bound, the start
/// that waited behind a finishing hold, the button ramp, the reset that releases the stop, and the mode change.
final class OperatingLinkTests: XCTestCase {
    private var transport: WireTransport!
    private var opened = 0
    private var clock = 10_000
    private var model: AppModel!
    private var rotation = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1))
    /// False while ARKit's tracking is limited: frames come with no camera pose.
    private var tracking = true
    private var savedMode: String?

    override func setUp() {
        super.setUp()
        savedMode = UserDefaults.standard.string(forKey: AppModel.controlModeKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(savedMode, forKey: AppModel.controlModeKey)
        model = nil
        super.tearDown()
    }

    private var camera: simd_float4x4? { tracking ? simd_float4x4(rotation) * TestPose.portrait : nil }

    private func bringUp(_ mode: ControlMode, state: [String: Any] = [:]) {
        opened = 0
        clock = 10_000
        tracking = true
        model = AppModel(
            start: .p4, haptics: NoHaptics(), sounds: SpySounds(), speech: SpySpeech(),
            pose: { [unowned self] in camera }, liveLink: true,
            makeTransport: { [unowned self] _ in
                opened += 1
                let made = WireTransport()
                if opened == 1 { transport = made }
                return made
            },
            nowMs: { [unowned self] in clock },
            inputClock: { [unowned self] in Double(clock) / 1000 }
        )
        model.controlMode = mode
        model.session.state.serverAddress = "100.64.0.1:8765"
        model.connect()
        transport.server("welcome")
        transport.server("state", ["estop": false, "gripper": "open"].merging(state) { $1 })
    }

    /// One frame of everything, 33 ms later: the phone's attitude, the input tick and the link tick, with a server
    /// that answers every probe as a live one does.
    private func step(_ count: Int = 1) {
        for _ in 0..<count {
            clock += 33
            let before = transport.sent.count
            model.poseFrame(camera, at: Double(clock) / 1000)
            model.controller.tick()
            model.link.tick()
            for message in transport.sent.dropFirst(before) where message["type"] as? String == "test" {
                transport.server("test", seq: message["seq"] as! Int)
            }
        }
    }

    private func turn(to degrees: Float) {
        rotation = simd_quatf(angle: -degrees * .pi / 180, axis: SIMD3(0, 0, 1))
    }

    private func lastRoll() -> Double? {
        guard let update = transport.sent.last(where: { $0["type"] as? String == "orient_update" }),
            let q = (update["payload"] as? [String: Any])?["q_rel"] as? [Double]
        else { return nil }
        return -2 * asin(q[1]) * 180 / .pi
    }

    private func seq(of type: String) -> Int {
        transport.sent.last { $0["type"] as? String == type }!["seq"] as! Int
    }

    private func touch(_ id: Int, _ phase: TouchSample.Phase, x: Double, y: Double) {
        model.touch(TouchSample(id: id, phase: phase, x: x, y: y, majorRadius: 8), at: Double(clock) / 1000)
    }

    func testThePhoneOffsetTakesItsSignsFromTheOperatorFrame() {
        let right = simd_normalize(SIMD3<Float>(0.8, 0, 0.6))
        let forward = simd_cross(SIMD3<Float>(0, 1, 0), right)
        for world in [SIMD3<Float>(0.1, 0, 0), SIMD3(0, 0.1, 0), SIMD3(0, 0, -0.1), SIMD3(0.03, -0.02, 0.05)] {
            let offset = OperatorFrame.linkOffset(
                right: Double(simd_dot(world, right)), forward: Double(simd_dot(world, forward)), up: Double(world.y)
            )
            let sent = LiveLinkController.serverOffset(world, right: right, forward: forward)
            XCTAssertEqual(Double(sent.x), offset.x, accuracy: 1e-6)
            XCTAssertEqual(Double(sent.y), offset.y, accuracy: 1e-6)
            XCTAssertEqual(Double(sent.z), offset.z, accuracy: 1e-6)
        }
        // And the axis table agrees with the server's calibration: right → −X, forward → −Y, up → +Z.
        XCTAssertEqual(
            OperatorFrame.base(fromLink: OperatorFrame.linkOffset(right: 1, forward: 0, up: 0)), SIMD3(-1, 0, 0))
        XCTAssertEqual(
            OperatorFrame.base(fromLink: OperatorFrame.linkOffset(right: 0, forward: 1, up: 0)), SIMD3(0, -1, 0))
        XCTAssertEqual(
            OperatorFrame.base(fromLink: OperatorFrame.linkOffset(right: 0, forward: 0, up: 1)), SIMD3(0, 0, 1))
    }

    /// Scheme B: vol− starts the wrist hold at once; the phone's turn becomes the target, and a frozen wrist holds the
    /// command to the measured angle + 2 degrees + 10 degrees a second of the newest state's age.
    func testAWristHoldStreamsThePhonesTurnThroughTheLeadBound() {
        bringUp(.keyTurns, state: ["wrist_roll_deg": 90.0, "wrist_flex_deg": 40.0])
        step()
        model.keyEvent(.lower, down: true)
        XCTAssertTrue(model.session.state.wristMoving)
        XCTAssertEqual(transport.types.filter { $0 == "orient_start" }.count, 1)
        step(3)
        XCTAssertEqual(lastRoll() ?? .nan, 0, accuracy: 1e-6, "identity until a turn commits")
        for degrees in stride(from: Float(2), through: 30, by: 2) {
            turn(to: degrees)
            step()
        }
        step(10)
        // The wrist has not moved: the command never led it by more than 2 + 10 × 0.4 s, and with no fresh state since
        // it has not moved further.
        XCTAssertLessThanOrEqual(lastRoll() ?? .nan, 6 + 1e-6)
        XCTAssertGreaterThan(lastRoll() ?? .nan, 0)
        transport.server("state", ["estop": false, "wrist_roll_deg": 101.0, "wrist_flex_deg": 40.0])
        step()
        XCTAssertEqual(lastRoll() ?? .nan, 11 + 2 + 0.33, accuracy: 0.05, "the allowance follows the wrist")
        model.keyEvent(.lower, down: false)
        XCTAssertFalse(model.session.state.wristMoving)
        XCTAssertEqual(transport.types.last, "orient_stop")
    }

    /// I-8.1: a wrist start that waits behind a finishing hold drops the rotation made while it waited.
    func testAWristStartHeldBackDropsTheTurnMadeWhileItWaited() {
        bringUp(.keyTurns)
        step()
        model.keyEvent(.upper, down: true)
        step(2)
        model.keyEvent(.upper, down: false)
        let poseStart = seq(of: "pose_start")
        // Past the 150 ms in which a key after the other key's release is taken for a reflex (I-2.4).
        step(6)
        model.keyEvent(.lower, down: true)
        XCTAssertFalse(transport.types.contains("orient_start"), "held back until the arm hold has finished")
        for degrees in stride(from: Float(2), through: 20, by: 2) {
            turn(to: degrees)
            step()
        }
        transport.server("ack", seq: poseStart, ["seq": poseStart, "status": "ok", "reason": "stopped"])
        XCTAssertTrue(transport.types.contains("orient_start"))
        step(3)
        XCTAssertEqual(lastRoll() ?? .nan, 0, accuracy: 1e-6, "the turn made while waiting does not count")
        for degrees in stride(from: Float(22), through: 30, by: 2) {
            turn(to: degrees)
            step()
        }
        step(15)
        XCTAssertEqual(lastRoll() ?? .nan, 10, accuracy: 0.2, "only the turn after the start went out")
        model.keyEvent(.lower, down: false)
    }

    /// A wrist start held back past the 800 ms wait goes out without the final ack. Its first update, in the same tick,
    /// is already measured from the hold's start and bounded: the turn made while waiting is dropped, and with the
    /// wrist reported still and no fresh state the command does not move away from it.
    func testAWristStartHeldBackPastTheWaitGoesOutBoundedAndReanchored() {
        bringUp(.keyTurns, state: ["wrist_roll_deg": 90.0, "wrist_flex_deg": 40.0])
        step()
        model.keyEvent(.upper, down: true)
        step(2)
        model.keyEvent(.upper, down: false)
        step(6)
        model.keyEvent(.lower, down: true)
        XCTAssertFalse(transport.types.contains("orient_start"), "held back until the arm hold has finished")
        for degrees in stride(from: Float(2), through: 20, by: 2) {
            turn(to: degrees)
            step()
        }
        // No final ack comes: the start goes out on its own after 800 ms.
        while !transport.types.contains("orient_start") { step() }
        let start = transport.sent.lastIndex { $0["type"] as? String == "orient_start" }!
        let rolls = transport.sent[start...].filter { $0["type"] as? String == "orient_update" }.map {
            message -> Double in
            let q = (message["payload"] as! [String: Any])["q_rel"] as! [Double]
            return -2 * asin(q[1]) * 180 / .pi
        }
        XCTAssertFalse(rolls.isEmpty)
        XCTAssertEqual(rolls.first ?? .nan, 0, accuracy: 1e-6, "the first update after the start: \(rolls)")
        step(5)
        XCTAssertEqual(lastRoll() ?? .nan, 0, accuracy: 1e-6, "no fresh state: the command stays with the still wrist")
        model.keyEvent(.lower, down: false)
    }

    /// Limited tracking (frames with no camera pose) ends a wrist hold, as it ends a translation hold: the phone's
    /// rotation is no longer known, so the wrist must not keep its last target as if it were.
    func testLimitedTrackingEndsAWristHold() {
        bringUp(.keyTurns, state: ["wrist_roll_deg": 90.0, "wrist_flex_deg": 40.0])
        step()
        model.keyEvent(.lower, down: true)
        XCTAssertTrue(model.session.state.wristMoving)
        for degrees in stride(from: Float(2), through: 10, by: 2) {
            turn(to: degrees)
            step()
        }
        tracking = false
        step(3)
        XCTAssertFalse(model.session.state.wristMoving, "the wrist hold ended")
        XCTAssertEqual(transport.types.filter { $0 == "orient_stop" }.count, 1)
        XCTAssertTrue(model.cueLog.contains { $0.event == .letGo(.tracking) }, "and says why")
        let sent = transport.sent.count
        step(10)
        XCTAssertFalse(transport.types.dropFirst(sent).contains("orient_update"))
        tracking = true
        step(3)
        XCTAssertFalse(model.session.state.wristMoving, "the key held across stays dead")
        model.keyEvent(.lower, down: false)
    }

    /// Buttons: the ramp is the translation target, 4 cm/s Coarse, through the 8 cm lead cap; release stops.
    func testAButtonHoldStreamsTheRampThroughTheLeadCap() {
        bringUp(.buttons, state: ["ee_pos": [0.02, -0.14, 0.16]])
        step()
        model.buttonDown(.up)
        XCTAssertTrue(model.session.state.armMoving)
        step(30)
        let p =
            (transport.sent.last { $0["type"] as? String == "pose_update" }?["payload"] as? [String: Any])?["p_rel_m"]
            as? [Double]
        // Up is base +Z, which the link frame sends as −z.
        XCTAssertEqual(p?[0] ?? .nan, 0, accuracy: 1e-6)
        XCTAssertEqual(p?[1] ?? .nan, 0, accuracy: 1e-6)
        XCTAssertEqual(p?[2] ?? .nan, -0.04 * 0.99, accuracy: 0.002)
        // Past 2 s the ramp asks for more than 8 cm: the update is capped, and a resync finds out where the arm got.
        step(40)
        let capped =
            (transport.sent.last { $0["type"] as? String == "pose_update" }?["payload"] as? [String: Any])?["p_rel_m"]
            as? [Double]
        XCTAssertEqual(capped?[2] ?? .nan, -0.08, accuracy: 1e-6, "never more than 8 cm ahead of the arm")
        model.buttonUp(.up)
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertTrue(transport.types.contains("pose_stop"))
    }

    /// I-11: opening Settings ends a pad hold with its stop, and the lift that comes later has nothing left to stop.
    func testAPadHoldEndsWithItsStopWhenSettingsOpens() {
        bringUp(.buttons, state: ["ee_pos": [0.02, -0.14, 0.16]])
        step()
        model.buttonDown(.up)
        step(3)
        XCTAssertTrue(model.session.state.armMoving)
        let before = transport.sent.count
        model.send(.openSettings)
        XCTAssertEqual(model.session.route, .s6)
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertTrue(transport.types.dropFirst(before).contains("pose_stop"))
        XCTAssertNil(model.operating.heldButton)
        let stopped = transport.sent.count
        model.buttonUp(.up)
        XCTAssertEqual(transport.sent.count, stopped, "the lift has nothing left to stop")
    }

    /// I-11: leaving the active state ends a pad hold with its stop; the button held across it stays down and dead, so
    /// another button does nothing until it is lifted.
    func testAPadHoldEndsWithItsStopWhenTheAppLeavesTheActiveState() {
        bringUp(.buttons)
        step()
        model.buttonDown(.close)
        step(3)
        XCTAssertEqual(model.session.state.gripperMoving, .closed)
        model.activeChanged(false)
        XCTAssertNil(model.session.state.gripperMoving)
        XCTAssertTrue(transport.types.contains("gripper_jog_stop"))
        model.activeChanged(true)
        let stopped = transport.sent.count
        step(10)
        XCTAssertFalse(transport.types.dropFirst(stopped).contains("jog_keepalive"), "the jaws are not kept moving")
        model.buttonDown(.open)
        XCTAssertNil(model.session.state.gripperMoving, "a press while the held-across button is down is dead")
        model.buttonUp(.open)
        model.buttonUp(.close)
        model.buttonDown(.open)
        XCTAssertEqual(model.session.state.gripperMoving, .open, "lifted, the pad works again")
        model.buttonUp(.open)
    }

    func testAPadHoldEndsWithItsStopWhenTheCameraStops() {
        bringUp(.buttons, state: ["ee_pos": [0.02, -0.14, 0.16]])
        step()
        model.buttonDown(.left)
        XCTAssertTrue(model.session.state.armMoving)
        let before = transport.sent.count
        model.controller.cameraInterrupted(true)
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertTrue(transport.types.dropFirst(before).contains("pose_stop"))
        model.controller.cameraInterrupted(false)
        model.buttonUp(.left)
    }

    /// I-3 in buttons mode: during a pad hold the top band is dead (NO + "Let go first.") and so is a gear tap.
    func testTheBandsAreDeadDuringAPadHold() {
        bringUp(.buttons, state: ["ee_pos": [0.02, -0.14, 0.16]])
        model.surfaceChanged(width: 402, height: 874, safeTop: 62, safeBottom: 34)
        step()
        let layout = model.operating.layout!
        model.buttonDown(.up)
        touch(3, .began, x: 200, y: layout.topBand.maxY - 20)
        step(70)
        XCTAssertNil(model.operating.resetCountdown)
        XCTAssertFalse(transport.types.contains("reset_scene"))
        XCTAssertTrue(model.cueLog.contains { $0.event == .refused(.letGoFirst) })
        touch(3, .ended, x: 200, y: layout.topBand.maxY - 20)
        let refusals = model.cueLog.filter { $0.event == .refused(.letGoFirst) }.count
        let gear = (x: layout.gear.x + layout.gear.width / 2, y: layout.gear.y + layout.gear.height / 2)
        touch(4, .began, x: gear.x, y: gear.y)
        step(3)
        touch(4, .ended, x: gear.x, y: gear.y)
        XCTAssertEqual(model.session.route, .p4, "Settings did not open")
        XCTAssertEqual(model.cueLog.filter { $0.event == .refused(.letGoFirst) }.count, refusals + 1)
        XCTAssertTrue(model.session.state.armMoving, "the hold runs on")
        model.buttonUp(.up)
        XCTAssertFalse(model.session.state.armMoving)
    }

    /// I-3 in buttons mode: the reset countdown counts as engaged, so a pad press during it is dead until released.
    func testAPadPressDuringTheResetCountdownIsDead() {
        bringUp(.buttons, state: ["ee_pos": [0.02, -0.14, 0.16]])
        model.surfaceChanged(width: 402, height: 874, safeTop: 62, safeBottom: 34)
        step()
        let top = model.operating.layout!.topBand.maxY - 20
        touch(3, .began, x: 200, y: top)
        step(10)
        XCTAssertNotNil(model.operating.resetCountdown)
        model.buttonDown(.up)
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertFalse(transport.types.contains("pose_start"))
        XCTAssertEqual(model.cueLog.last?.event, .refused(.deadInput))
        touch(3, .ended, x: 200, y: top)
        step()
        XCTAssertFalse(model.session.state.armMoving, "still dead after the countdown")
        model.buttonUp(.up)
        model.buttonDown(.up)
        XCTAssertTrue(model.session.state.armMoving, "lifted, the button works again")
        model.buttonUp(.up)
    }

    func testFineAndCoarseAreRefusedWhileAButtonIsDown() {
        bringUp(.buttons)
        model.buttonDown(.left)
        model.selectSpeed(.fine)
        XCTAssertEqual(model.operating.speed, .coarse)
        model.buttonUp(.left)
        model.selectSpeed(.fine)
        XCTAssertEqual(model.operating.speed, .fine)
    }

    /// The top band held 2 s while stopped sends reset_scene, never estop_reset, and the server's ok releases the stop.
    func testTheServersResetReleasesTheStop() {
        bringUp(.screenTurns)
        model.surfaceChanged(width: 402, height: 874, safeTop: 62, safeBottom: 34)
        step()
        let layout = model.operating.layout!
        let bottom = layout.bottomBand
        model.touch(
            TouchSample(id: 1, phase: .began, x: 200, y: bottom.y + 20, majorRadius: 8), at: Double(clock) / 1000)
        XCTAssertTrue(model.session.state.emergencyStop)
        XCTAssertEqual(transport.types.last, "estop")
        model.touch(
            TouchSample(id: 1, phase: .ended, x: 200, y: bottom.y + 20, majorRadius: 8), at: Double(clock) / 1000)
        transport.server("state", ["estop": true])

        model.touch(
            TouchSample(id: 2, phase: .began, x: 200, y: layout.topBand.maxY - 20, majorRadius: 8),
            at: Double(clock) / 1000)
        step(45)
        XCTAssertEqual(model.operating.resetCountdown ?? 0, 0.7, accuracy: 0.05)
        XCTAssertFalse(transport.types.contains("reset_scene"))
        step(20)
        XCTAssertTrue(transport.types.contains("reset_scene"))
        XCTAssertTrue(model.session.state.emergencyStop, "asking for the reset releases nothing")
        model.touch(
            TouchSample(id: 2, phase: .ended, x: 200, y: layout.topBand.maxY - 20, majorRadius: 8),
            at: Double(clock) / 1000)
        let reset = seq(of: "reset_scene")
        transport.server("state", ["estop": false, "ik": "resetting"])
        transport.server("ack", seq: reset, ["seq": reset, "status": "ok", "reason": "scene_reset"])
        XCTAssertFalse(model.session.state.emergencyStop)
        XCTAssertFalse(transport.types.contains("estop_reset"))
        XCTAssertEqual(model.session.route, .p4)
    }

    /// I-3: STOP pressed while the reset asked for in the stop state is in flight still goes out (the server clears
    /// its own stop when the reset arrives), and the reset's ok no longer releases the stop.
    func testAStopDuringTheResetFromTheStopStateGoesOutAndStaysLatched() {
        bringUp(.screenTurns)
        model.surfaceChanged(width: 402, height: 874, safeTop: 62, safeBottom: 34)
        step()
        let layout = model.operating.layout!
        let bottom = layout.bottomBand.y + 20
        let top = layout.topBand.maxY - 20
        touch(1, .began, x: 200, y: bottom)
        touch(1, .ended, x: 200, y: bottom)
        transport.server("state", ["estop": true])
        touch(2, .began, x: 200, y: top)
        step(65)
        XCTAssertTrue(transport.types.contains("reset_scene"))
        touch(2, .ended, x: 200, y: top)
        let reset = seq(of: "reset_scene")
        let estops = transport.types.filter { $0 == "estop" }.count
        step()
        touch(4, .began, x: 200, y: bottom)
        touch(4, .ended, x: 200, y: bottom)
        XCTAssertEqual(transport.types.filter { $0 == "estop" }.count, estops + 1, "the second STOP goes out")
        transport.server("ack", seq: reset, ["seq": reset, "status": "ok", "reason": "scene_reset"])
        XCTAssertTrue(model.session.state.emergencyStop)
        XCTAssertEqual(model.operating.state, .stopped(cause: .button))
        XCTAssertFalse(transport.types.contains("estop_reset"))
    }

    /// The ok of a reset asked for before STOP releases nothing: the operator's STOP came last.
    func testTheOkOfAResetAskedForBeforeTheStopReleasesNothing() {
        bringUp(.screenTurns)
        model.surfaceChanged(width: 402, height: 874, safeTop: 62, safeBottom: 34)
        step()
        let layout = model.operating.layout!
        let top = layout.topBand.maxY - 20
        touch(2, .began, x: 200, y: top)
        step(65)
        XCTAssertTrue(transport.types.contains("reset_scene"))
        touch(2, .ended, x: 200, y: top)
        let reset = seq(of: "reset_scene")
        step()
        touch(4, .began, x: 200, y: layout.bottomBand.y + 20)
        touch(4, .ended, x: 200, y: layout.bottomBand.y + 20)
        XCTAssertTrue(model.session.state.emergencyStop)
        transport.server("ack", seq: reset, ["seq": reset, "status": "ok", "reason": "scene_reset"])
        XCTAssertTrue(model.session.state.emergencyStop)
        XCTAssertEqual(model.session.route, .s4)
    }

    /// §2.8, J7: STOP with no connection up says "No link. Not stopped.", and the screen shows the lost link, not
    /// STOPPED: no estop reached any server.
    func testAStopThatReachedNoServerIsNotShownAsStopped() {
        bringUp(.screenTurns)
        model.surfaceChanged(width: 402, height: 874, safeTop: 62, safeBottom: 34)
        step()
        transport.onClose?()
        step()
        XCTAssertFalse(model.session.state.connected)
        let bottom = model.operating.layout!.bottomBand.y + 20
        touch(1, .began, x: 200, y: bottom)
        touch(1, .ended, x: 200, y: bottom)
        XCTAssertTrue(model.cueLog.contains { $0.event == .refused(.notStopped) })
        XCTAssertEqual(model.operating.state, .linkLost)
    }

    /// J7: a STOP touched with the link up goes out at once, but if the socket closes before a `state` the server wrote
    /// after reading that `estop` says stopped, it is owed like one touched with no link: "No link. Not stopped." and
    /// the lost link on the screen. Once such a state has come, the screen keeps saying STOPPED.
    func testAStopTheServerHasNotConfirmedIsOwedWhenTheSocketCloses() {
        for confirmed in [false, true] {
            bringUp(.screenTurns)
            model.surfaceChanged(width: 402, height: 874, safeTop: 62, safeBottom: 34)
            step()
            let bottom = model.operating.layout!.bottomBand.y + 20
            touch(1, .began, x: 200, y: bottom)
            touch(1, .ended, x: 200, y: bottom)
            XCTAssertEqual(transport.types.last, "estop", "\(confirmed)")
            XCTAssertEqual(model.operating.state, .stopped(cause: .button), "\(confirmed)")
            if confirmed { transport.server("state", seq: seq(of: "estop"), ["estop": true]) }
            step(10)
            transport.onClose?()
            step()
            XCTAssertEqual(model.operating.state, confirmed ? .stopped(cause: .button) : .linkLost, "\(confirmed)")
            XCTAssertEqual(model.cueLog.contains { $0.event == .refused(.notStopped) }, !confirmed, "\(confirmed)")
        }
    }

    /// J7: while that STOP waits for the next welcome the robot is not stopped, so a press says "No link.", as the
    /// screen does, never "Stopped.".
    func testWhileAStopWaitsForTheLinkAPressSaysNoLink() {
        bringUp(.screenTurns)
        model.surfaceChanged(width: 402, height: 874, safeTop: 62, safeBottom: 34)
        step()
        transport.onClose?()
        step()
        let bottom = model.operating.layout!.bottomBand.y + 20
        touch(1, .began, x: 200, y: bottom)
        touch(1, .ended, x: 200, y: bottom)
        XCTAssertTrue(model.session.state.emergencyStop, "the stop stays latched until it is sent")
        step(10)
        model.keyEvent(.upper, down: true)
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertEqual(model.cueLog.last?.event, .refused(.noLink))
        model.keyEvent(.upper, down: false)
        XCTAssertEqual(model.operating.state, .linkLost)
    }

    /// The same while Connect replaces a link that is up: the session still reads connected, but a STOP touched before
    /// the new welcome has reached no robot, so a press says "No link." and the screen says Connecting.
    func testWhileAStopWaitsForAReplacedLinkAPressSaysNoLink() {
        bringUp(.screenTurns)
        model.surfaceChanged(width: 402, height: 874, safeTop: 62, safeBottom: 34)
        step()
        model.connect()
        step()
        let bottom = model.operating.layout!.bottomBand.y + 20
        touch(1, .began, x: 200, y: bottom)
        touch(1, .ended, x: 200, y: bottom)
        XCTAssertTrue(model.session.state.emergencyStop)
        XCTAssertTrue(model.session.state.connected, "Connect is replacing the link")
        XCTAssertTrue(model.cueLog.contains { $0.event == .refused(.notStopped) })
        step(10)
        model.keyEvent(.upper, down: true)
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertEqual(model.cueLog.last?.event, .refused(.noLink))
        model.keyEvent(.upper, down: false)
        XCTAssertEqual(model.operating.state, .connecting(address: "100.64.0.1:8765"))
    }

    func testTheModeCannotChangeWhileAHoldIsEngaged() {
        bringUp(.screenTurns)
        step()
        model.keyEvent(.upper, down: true)
        model.controlMode = .buttons
        XCTAssertEqual(model.controlMode, .screenTurns)
        XCTAssertTrue(model.cueLog.contains { $0.event == .refused(.letGoFirst) })
        model.keyEvent(.upper, down: false)
        model.controlMode = .keyTurns
        XCTAssertEqual(model.controlMode, .keyTurns)
        XCTAssertEqual(model.operating.mode, .keyTurns)
    }

    /// Practice reaches no server: no socket opens, whatever is pressed.
    func testPracticeOpensNoSocket() {
        var sockets = 0
        UserDefaults.standard.set(ControlMode.screenTurns.rawValue, forKey: AppModel.controlModeKey)
        let practice = AppModel(
            start: .p4, haptics: NoHaptics(), pose: { TestPose.portrait }, liveLink: false,
            makeTransport: { _ in
                sockets += 1; return WireTransport()
            },
            makeObserverTransport: { _ in
                sockets += 1; return WireTransport()
            }
        )
        practice.keyEvent(.upper, down: true)
        XCTAssertTrue(practice.session.state.armMoving, "the practice arm moves")
        practice.keyEvent(.upper, down: false)
        practice.trySavedServer()
        practice.connect()
        XCTAssertEqual(sockets, 0)
    }
}
