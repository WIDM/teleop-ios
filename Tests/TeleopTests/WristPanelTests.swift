import TeleopCore
import XCTest

@testable import Teleop

private final class WristTransport: LinkTransport {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    var sent: [[String: Any]] = []
    var time: () -> Int = { 0 }
    func open() {}
    func close() {}
    /// The server closes the connection.
    func serverCloses() { onClose?() }
    func send(_ text: String) {
        sent.append(try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])
    }
    func server(_ type: String, seq: Int = 0, _ payload: [String: Any] = [:]) {
        let message: [String: Any] = ["v": 1, "type": type, "ts": time(), "seq": seq, "payload": payload]
        onText?(String(data: try! JSONSerialization.data(withJSONObject: message), encoding: .utf8)!)
    }
    func count(_ type: String) -> Int { sent.filter { $0["type"] as? String == type }.count }
    func last(_ type: String) -> [String: Any]? { sent.last { $0["type"] as? String == type } }
}

/// The fine panel's wrist page, and the reasons a one-phone server gives for refusing or letting go of a phone.
final class WristPanelTests: XCTestCase {
    private var model: AppModel!
    private var wire: WristTransport!
    private var clock = 10_000
    private var tracking = true
    private var saved: [String: Any] = [:]
    private let keys = [AppModel.controlModeKey, AppModel.taskAidKey, AppModel.assistKey, AppModel.lockChoiceKey]
    private let state: [String: Any] = [
        "estop": false, "gripper": "open", "ee_pos": [0.0, -0.14, 0.16], "wrist_roll_deg": 90.0,
        "wrist_flex_deg": 40.0,
    ]

    override func setUp() {
        super.setUp()
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
    }

    override func tearDown() {
        model = nil
        wire = nil
        for key in keys { UserDefaults.standard.set(saved[key], forKey: key) }
        super.tearDown()
    }

    private func bringUp() {
        clock = 10_000
        tracking = true
        UserDefaults.standard.set(false, forKey: AppModel.taskAidKey)
        model = AppModel(
            start: .p4, haptics: NoHaptics(), sounds: SpySounds(), speech: SpySpeech(),
            pose: { [unowned self] in tracking ? TestPose.portrait : nil }, liveLink: true,
            makeTransport: { [unowned self] _ in
                let made = WristTransport()
                made.time = { [unowned self] in clock }
                wire = made
                return made
            },
            makeObserverTransport: { _ in WristTransport() },
            nowMs: { [unowned self] in clock }, inputClock: { [unowned self] in Double(clock) / 1000 },
            assistOn: false, lockChoice: .off
        )
        model.controlMode = .screenTurns
        model.session.state.serverAddress = "100.64.0.1:8765"
        model.connect()
        wire.server("welcome")
        wire.server("state", state)
        model.surfaceChanged(width: 375, height: 667, safeTop: 20, safeBottom: 0)
    }

    private func tick(_ count: Int = 1) {
        for _ in 0..<count {
            clock += 33
            let before = wire.sent.count
            model.controller.tick()
            model.link.tick()
            for message in Array(wire.sent.dropFirst(before)) where message["type"] as? String == "test" {
                wire.server("test", seq: message["seq"] as! Int)
            }
        }
    }

    /// Ticks with a server whose wrist follows what was asked, as a healthy one does; the lead bound then never holds
    /// the angle back.
    private func tickFollowing(_ count: Int) {
        for _ in 0..<count {
            tick()
            var now = state
            if let (axis, degrees) = lastAngle() {
                if axis == .tilt {
                    now["wrist_flex_deg"] = 40.0 + degrees
                } else {
                    now["wrist_roll_deg"] = 90.0 + degrees
                }
            }
            wire.server("state", now)
        }
    }

    /// The angle the newest `orient_update` asks for: (axis, server degrees).
    private func lastAngle() -> (WristAxis, Double)? {
        guard let q = (wire.last("orient_update")?["payload"] as? [String: Any])?["q_rel"] as? [Double] else {
            return nil
        }
        if abs(q[0]) > 1e-9 { return (.tilt, 2 * asin(q[0]) * 180 / .pi) }
        return (.turn, -2 * asin(q[1]) * 180 / .pi)
    }

    private func openWristPage() {
        model.setPrecisionPanelOpen(true)
        XCTAssertTrue(model.operating.precisionPanelOpen)
        model.setPanelPage(.wrist)
        XCTAssertEqual(model.operating.panelPage, .wrist)
    }

    private func heard(since mark: Int) -> [CueKey] { model.cueLog.dropFirst(mark).map(\.event) }

    // MARK: Pages

    func testThePanelOpensOnTheMovePageAndReturnsToItWhenClosed() {
        bringUp()
        model.setPrecisionPanelOpen(true)
        XCTAssertEqual(model.operating.panelPage, .move)
        model.setPanelPage(.wrist)
        XCTAssertEqual(model.operating.panelPage, .wrist)
        model.setPrecisionPanelOpen(false)
        model.setPrecisionPanelOpen(true)
        XCTAssertEqual(model.operating.panelPage, .move)
    }

    func testThePageDoesNotChangeWhileAFingerIsOnAButton() {
        bringUp()
        model.setPrecisionPanelOpen(true)
        model.buttonDown(.up)
        let mark = model.cueLog.count
        model.setPanelPage(.wrist)
        XCTAssertEqual(model.operating.panelPage, .move)
        XCTAssertEqual(heard(since: mark), [.refused(.letGoFirst)])
        model.buttonUp(.up)
        openWristPageAfterStop()
        model.wristButtonDown(.tiltDown)
        model.setPanelPage(.move)
        XCTAssertEqual(model.operating.panelPage, .wrist, "a wrist button down holds the page too")
        model.wristButtonUp(.tiltDown)
    }

    private func openWristPageAfterStop() {
        let start = wire.sent.last { $0["type"] as? String == "pose_start" }!["seq"] as! Int
        wire.server("ack", seq: start, ["seq": start, "status": "ok", "reason": "pose_stopped"])
        wire.server("state", state)
        model.setPanelPage(.wrist)
        XCTAssertEqual(model.operating.panelPage, .wrist)
    }

    // MARK: The wrist buttons

    func testEachWristButtonSendsItsAxisAtItsRateFromWhenTheStartWentOut() {
        let expected: [(WristButton, WristAxis, Double)] = [
            (.tiltDown, .tilt, 10), (.tiltUp, .tilt, -10), (.turnRight, .turn, 20), (.turnLeft, .turn, -20),
        ]
        for (button, axis, rate) in expected {
            bringUp()
            openWristPage()
            model.wristButtonDown(button)
            XCTAssertEqual(wire.count("orient_start"), 1, "\(button)")
            XCTAssertEqual(model.operating.heldWrist, button)
            tickFollowing(15)  // about 0.5 s
            guard let (sentAxis, degrees) = lastAngle() else { return XCTFail("\(button): no update") }
            XCTAssertEqual(sentAxis, axis, "\(button)")
            XCTAssertEqual(degrees, rate * 0.495, accuracy: abs(rate) * 0.07, "\(button)")
            model.wristButtonUp(button)
            XCTAssertEqual(wire.count("orient_stop"), 1, "\(button): one stop")
            XCTAssertNil(model.operating.heldWrist)
            tick(3)
            XCTAssertEqual(wire.count("orient_stop"), 1, "\(button): still one")
        }
    }

    func testTheAngleStopsAtTheWindowAndTheLimitIsFeltOnce() {
        bringUp()
        var near = state
        near["wrist_flex_deg"] = 60.0  // 20 of the 25 degrees used since the reset at 40
        wire.server("state", near)
        // The tilt window counts from the flex after the last reset, which this server reported as 40.
        openWristPage()
        let mark = model.cueLog.count
        model.wristButtonDown(.tiltDown)
        tick(60)  // 2 s at 10 degrees a second would be 20
        guard let (_, degrees) = lastAngle() else { return XCTFail("no update") }
        XCTAssertLessThanOrEqual(degrees, 5.0 + 1e-6, "held to the 25 degree window")
        XCTAssertEqual(heard(since: mark).filter { $0 == .limit(.wrist) }.count, 1)
        model.wristButtonUp(.tiltDown)
    }

    func testAWristButtonOnTheMovePageOrWithTheJawsMovingIsDead() {
        bringUp()
        model.setPrecisionPanelOpen(true)
        var mark = model.cueLog.count
        model.wristButtonDown(.turnLeft)
        XCTAssertEqual(wire.count("orient_start"), 0, "not on the move page")
        XCTAssertEqual(heard(since: mark), [.refused(.deadInput)])
        model.wristButtonUp(.turnLeft)
        model.setPanelPage(.wrist)
        model.buttonDown(.close)
        XCTAssertEqual(model.session.state.gripperMoving, .closed)
        mark = model.cueLog.count
        model.wristButtonDown(.turnLeft)
        XCTAssertEqual(wire.count("orient_start"), 0, "the jaws are moving")
        model.wristButtonUp(.turnLeft)
        model.buttonUp(.close)
    }

    func testAMoveButtonWhileAWristButtonIsDownIsDead() {
        bringUp()
        openWristPage()
        model.wristButtonDown(.turnRight)
        model.buttonDown(.up)
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertEqual(wire.count("pose_start"), 0)
        model.buttonUp(.up)
        model.wristButtonUp(.turnRight)
    }

    func testStopBackgroundAndClosingThePanelEndTheWristHoldOnce() {
        let endings: [(String, (AppModel, WristPanelTests) -> Void)] = [
            ("STOP", { model, _ in model.send(.stop) }),
            ("background", { model, _ in model.activeChanged(false) }),
            ("closing the panel", { model, _ in model.setPrecisionPanelOpen(false) }),
        ]
        for (name, end) in endings {
            bringUp()
            openWristPage()
            model.wristButtonDown(.turnRight)
            tick(5)
            end(model, self)
            XCTAssertFalse(model.session.state.wristMoving, name)
            XCTAssertNil(model.controller.wristRamp, name)
            tick(5)
            XCTAssertLessThanOrEqual(wire.count("orient_stop"), 1, name)
            let updates = wire.count("orient_update")
            tick(5)
            XCTAssertEqual(wire.count("orient_update"), updates, "\(name): nothing more goes out")
            model.activeChanged(true)
            model.wristButtonUp(.turnRight)
        }
    }

    func testLosingTheCameraDoesNotEndAWristButtonsHold() {
        bringUp()
        openWristPage()
        model.wristButtonDown(.tiltUp)
        tick(3)
        tracking = false
        tick(10)
        XCTAssertTrue(model.session.state.wristMoving, "the panel does not need the phone's pose")
        XCTAssertEqual(wire.count("orient_stop"), 0)
        model.wristButtonUp(.tiltUp)
        XCTAssertEqual(wire.count("orient_stop"), 1)
    }

    func testAServerThatEndsTheHoldEndsTheButtonsHold() {
        bringUp()
        openWristPage()
        model.wristButtonDown(.turnLeft)
        tick(3)
        let start = wire.last("orient_start")!["seq"] as! Int
        wire.server("ack", seq: start, ["seq": start, "status": "ok", "reason": "orient_watchdog_timeout"])
        tick(3)
        XCTAssertNil(model.controller.wristRamp)
        XCTAssertNil(model.operating.heldWrist)
        model.wristButtonUp(.turnLeft)
    }

    // MARK: A server that keeps one phone per simulator

    func testARefusedPhoneIsToldTheSimulatorIsInUse() {
        clock = 10_000
        UserDefaults.standard.set(false, forKey: AppModel.taskAidKey)
        model = AppModel(
            start: .s1, haptics: NoHaptics(), sounds: SpySounds(), speech: SpySpeech(),
            pose: { TestPose.portrait }, liveLink: true,
            makeTransport: { [unowned self] _ in
                let made = WristTransport()
                wire = made
                return made
            },
            makeObserverTransport: { _ in WristTransport() },
            nowMs: { [unowned self] in clock }, inputClock: { [unowned self] in Double(clock) / 1000 },
            assistOn: false, lockChoice: .off
        )
        model.session.state.serverAddress = "100.64.0.1:8765"
        model.connect()
        wire.server("error", ["code": "session_in_use", "msg": "this simulator is in use"])
        wire.serverCloses()
        XCTAssertEqual(model.session.state.dismissal, .inUse)
        XCTAssertFalse(model.session.state.connected)
        model.connect()
        wire.server("welcome")
        wire.server("state", state)
        XCTAssertNil(model.session.state.dismissal, "a new connection clears it")
    }

    func testAnIdlePhoneLetGoSeesWhyOnTheLinkLostAndStoppedStates() {
        for stopped in [false, true] {
            bringUp()
            if stopped {
                model.send(.stop)
                wire.server("state", state.merging(["estop": true]) { $1 })
            }
            wire.server("error", ["code": "idle_timeout", "msg": "no operation for too long"])
            wire.serverCloses()
            XCTAssertEqual(model.session.state.dismissal, .idle, "stopped \(stopped)")
            let words = OperatingWords.look(model.operating).details
            XCTAssertTrue(
                words.contains(OperatingWords.dismissal(.idle)), "stopped \(stopped): \(words)")
        }
    }

    func testTheResetBandAndTheGearAreDeadDuringAWristButtonsHold() {
        bringUp()
        openWristPage()
        model.wristButtonDown(.turnRight)
        tick(2)
        let mark = model.cueLog.count
        let band = model.operating.layout!.topBand
        model.touch(
            TouchSample(id: 7, phase: .began, x: 200, y: band.maxY - 20, majorRadius: 8), at: Double(clock) / 1000)
        tick(30)  // inside the 2 s a countdown would take
        XCTAssertNil(model.operating.resetCountdown, "no countdown while the wrist moves")
        model.wristButtonUp(.turnRight)
        tick(80)  // the band still held, past when a countdown begun at the touch would have fired
        XCTAssertNil(model.operating.resetCountdown, "the refused touch stays dead after the wrist button lifts")
        XCTAssertEqual(wire.count("reset_scene"), 0)
        model.touch(
            TouchSample(id: 7, phase: .ended, x: 200, y: band.maxY - 20, majorRadius: 8), at: Double(clock) / 1000)
        XCTAssertTrue(heard(since: mark).contains(.refused(.letGoFirst)))

        let gear = model.operating.layout!.gear
        let centre = (x: gear.x + gear.width / 2, y: gear.y + gear.height / 2)
        model.wristButtonDown(.turnRight)
        model.touch(
            TouchSample(id: 8, phase: .began, x: centre.x, y: centre.y, majorRadius: 8), at: Double(clock) / 1000)
        model.wristButtonUp(.turnRight)  // the wrist lets go first, the gear touch after
        model.touch(
            TouchSample(id: 8, phase: .ended, x: centre.x, y: centre.y, majorRadius: 8),
            at: Double(clock) / 1000 + 0.05)
        XCTAssertNotEqual(model.session.route, .s6, "a gear touch begun during the wrist hold stays dead")
    }

    func testAKeyOrATouchStillDownMakesAWristButtonDead() {
        bringUp()
        openWristPage()
        model.keyEvent(.upper, down: true)
        model.wristButtonDown(.tiltUp)
        XCTAssertEqual(wire.count("orient_start"), 0, "the volume key the panel swallowed is still down")
        model.wristButtonUp(.tiltUp)
        model.keyEvent(.upper, down: false)
        let surface = model.operating.layout!.controlSurface
        model.touch(
            TouchSample(id: 3, phase: .began, x: (surface.x + surface.width / 2), y: surface.y + 10, majorRadius: 8),
            at: Double(clock) / 1000)
        model.wristButtonDown(.tiltUp)
        XCTAssertEqual(wire.count("orient_start"), 0, "a touch on the panel's margin is still down")
        model.wristButtonUp(.tiltUp)
        model.touch(
            TouchSample(id: 3, phase: .ended, x: (surface.x + surface.width / 2), y: surface.y + 10, majorRadius: 8),
            at: Double(clock) / 1000)
        model.wristButtonDown(.tiltUp)
        XCTAssertEqual(wire.count("orient_start"), 1)
        model.wristButtonUp(.tiltUp)
    }

    func testAFingerThatSlidOffKeepsThePageUntilItLifts() {
        bringUp()
        openWristPage()
        model.wristButtonDown(.turnLeft)
        tick(3)
        model.wristButtonSlipped(.turnLeft)
        XCTAssertEqual(wire.count("orient_stop"), 1, "sliding off ends the hold")
        model.setPanelPage(.move)
        XCTAssertEqual(model.operating.panelPage, .wrist, "the finger is still down")
        model.wristButtonUp(.turnLeft)
        model.setPanelPage(.move)
        XCTAssertEqual(model.operating.panelPage, .move)
        model.buttonDown(.open)
        model.buttonSlipped(.open)
        model.setPanelPage(.wrist)
        XCTAssertEqual(model.operating.panelPage, .move, "the same for a move page button")
        model.buttonUp(.open)
    }

    func testCameraStopAndLinkLossEndTheWristButtonsHold() {
        for ending in ["camera", "link"] {
            bringUp()
            openWristPage()
            model.wristButtonDown(.tiltDown)
            tick(3)
            if ending == "camera" { model.controller.cameraInterrupted(true) } else { wire.serverCloses() }
            tick(2)
            XCTAssertFalse(model.session.state.wristMoving, ending)
            XCTAssertNil(model.controller.wristRamp, ending)
            model.wristButtonUp(.tiltDown)
        }
    }

    func testReleasingWhileTheStartWaitsSendsNothing() {
        bringUp()
        model.setPrecisionPanelOpen(true)
        model.buttonDown(.close)
        model.buttonUp(.close)  // its stop is not answered yet, so a new start waits behind it
        model.setPanelPage(.wrist)
        let starts = wire.count("orient_start")
        model.wristButtonDown(.turnRight)
        XCTAssertEqual(wire.count("orient_start"), starts, "waiting behind the finishing jaws")
        model.wristButtonUp(.turnRight)
        let stop = wire.last("gripper_jog_start")!["seq"] as! Int
        wire.server("ack", seq: stop, ["seq": stop, "status": "ok", "reason": "gripper_jog_stopped"])
        tick(5)
        XCTAssertEqual(wire.count("orient_start"), starts, "released before it went out: it never does")
        XCTAssertEqual(wire.count("orient_update"), 0)
    }

    func testTheAngleCountsFromWhenAWaitingStartWentOut() {
        bringUp()
        model.setPrecisionPanelOpen(true)
        model.buttonDown(.close)
        model.buttonUp(.close)
        model.setPanelPage(.wrist)
        let starts = wire.count("orient_start")
        model.wristButtonDown(.tiltDown)
        tick(15)  // half a second waiting behind the finishing jaws
        XCTAssertEqual(wire.count("orient_start"), starts)
        let jog = wire.last("gripper_jog_start")!["seq"] as! Int
        wire.server("ack", seq: jog, ["seq": jog, "status": "ok", "reason": "gripper_jog_stopped"])
        tickFollowing(3)
        XCTAssertEqual(wire.count("orient_start"), starts + 1)
        guard let (_, degrees) = lastAngle() else { return XCTFail("no update") }
        XCTAssertLessThan(degrees, 2.0, "the half second of waiting is not counted")
        model.wristButtonUp(.tiltDown)
    }

    func testTurnStaysInsideTheRollWindow() {
        bringUp()
        var near = state
        near["wrist_roll_deg"] = 140.0
        wire.server("state", near)
        openWristPage()
        model.wristButtonDown(.turnRight)
        for _ in 0..<45 {
            tick()
            var now = near
            if let (_, degrees) = lastAngle() { now["wrist_roll_deg"] = 140.0 + degrees }
            wire.server("state", now)  // the wrist follows, so the lead bound holds nothing back
        }
        guard let (axis, degrees) = lastAngle() else { return XCTFail("no update") }
        XCTAssertEqual(axis, .turn)
        XCTAssertLessThanOrEqual(degrees, 10.0 + 1e-3, "150 degrees either way of zero, from a roll of 140")
        XCTAssertGreaterThan(degrees, 9.0, "and it gets there")
        model.wristButtonUp(.turnRight)
    }

    func testAServerLimitAndThePanelsOwnLimitAreFeltOnceBetweenThem() {
        bringUp()
        openWristPage()
        let mark = model.cueLog.count
        model.wristButtonDown(.tiltDown)
        tick(3)
        model.raise(.limit(.wrist))  // as the feedback monitor does when the server reports orient_clamped
        tick(80)  // the panel's own range is reached too
        XCTAssertEqual(heard(since: mark).filter { $0 == .limit(.wrist) }.count, 1)
        model.wristButtonUp(.tiltDown)
    }

    func testANewAttemptForgetsTheLastServersReason() {
        bringUp()
        wire.server("error", ["code": "session_taken", "msg": "another phone took this simulator"])
        XCTAssertEqual(model.session.state.dismissal, .taken)
        wire.serverCloses()
        model.connect()
        XCTAssertNil(model.session.state.dismissal, "a new attempt starts without the old reason")
    }

    func testOtherServerErrorsAreNotDismissals() {
        bringUp()
        wire.server("error", ["code": "invalid_json", "msg": "unable to parse JSON"])
        XCTAssertNil(model.session.state.dismissal)
        XCTAssertTrue(model.session.state.connected)
    }
}
