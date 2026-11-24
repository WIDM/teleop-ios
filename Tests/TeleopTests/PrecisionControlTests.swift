import simd
import TeleopCore
import XCTest
@testable import Teleop

private final class PrecisionTransport: LinkTransport {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    var sent: [[String: Any]] = []
    var time: () -> Int = { 0 }
    func open() {}
    func close() {}
    func send(_ text: String) {
        sent.append(try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])
    }
    func server(_ type: String, seq: Int = 0, _ payload: [String: Any] = [:]) {
        let message: [String: Any] = ["v": 1, "type": type, "ts": time(), "seq": seq, "payload": payload]
        onText?(String(data: try! JSONSerialization.data(withJSONObject: message), encoding: .utf8)!)
    }
    func count(_ type: String) -> Int { sent.filter { $0["type"] as? String == type }.count }
}

final class PrecisionControlTests: XCTestCase {
    private var model: AppModel!
    private var wire: PrecisionTransport!
    private var clock = 10_000
    private var saved: [String: Any] = [:]
    private let keys = [AppModel.controlModeKey, AppModel.taskAidKey, AppModel.assistKey, AppModel.lockChoiceKey]

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

    private func bringUp(_ mode: ControlMode = .screenTurns, tracking: Bool = true, lock: LockChoice = .off) {
        clock = 10_000
        UserDefaults.standard.set(false, forKey: AppModel.taskAidKey)
        model = AppModel(
            start: .p4, haptics: NoHaptics(), sounds: SpySounds(), speech: SpySpeech(),
            pose: { tracking ? TestPose.portrait : nil }, liveLink: true,
            makeTransport: { [unowned self] _ in
                let made = PrecisionTransport()
                made.time = { [unowned self] in clock }
                wire = made
                return made
            },
            makeObserverTransport: { _ in PrecisionTransport() },
            nowMs: { [unowned self] in clock }, inputClock: { [unowned self] in Double(clock) / 1000 },
            assistOn: lock != .off, lockChoice: lock
        )
        model.controlMode = mode
        model.session.state.serverAddress = "100.64.0.1:8765"
        model.connect()
        wire.server("welcome")
        wire.server("state", ["estop": false, "gripper": "open", "ee_pos": [0.0, -0.14, 0.16]])
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

    private func acknowledgeStop() {
        let start = wire.sent.last { $0["type"] as? String == "pose_start" }!["seq"] as! Int
        wire.server("ack", seq: start, ["seq": start, "status": "ok", "reason": "pose_stopped"])
        XCTAssertFalse(model.link.armHeardAfterLastStop, "the stop ack alone is not a fresh arm reading")
        wire.server("state", ["estop": false, "gripper": "open", "ee_pos": [0.0, -0.14, 0.16]])
        XCTAssertTrue(model.link.armHeardAfterLastStop)
    }

    private func touch(_ id: Int, _ phase: TouchSample.Phase, x: Double = 100, y: Double = 350) {
        model.touch(TouchSample(id: id, phase: phase, x: x, y: y, majorRadius: 8), at: Double(clock) / 1000)
    }

    func testTaskAidLoadsBooleanAndLaunchArgumentStringWithoutChangingDefault() {
        let cases: [(Any?, Bool)] = [(nil, true), (true, true), (false, false), ("YES", true), ("NO", false)]
        for (saved, expected) in cases {
            UserDefaults.standard.set(saved, forKey: AppModel.taskAidKey)
            model = AppModel(
                start: .p4, haptics: NoHaptics(), sounds: SpySounds(), speech: SpySpeech(), liveLink: false,
                assistOn: false, lockChoice: .off
            )
            XCTAssertEqual(model.taskAid, expected, "saved value: \(String(describing: saved))")
            XCTAssertEqual(model.operating.taskAid, expected, "the operating screen must use the loaded choice")
        }
    }

    func testFineTranslationAndJawsNeedNoAidTargetOrCameraAndDoNotPersistMode() {
        for mode in [ControlMode.screenTurns, .keyTurns] {
            bringUp(mode, tracking: false)
            let persisted = UserDefaults.standard.string(forKey: AppModel.controlModeKey)
            model.setPrecisionPanelOpen(true)
            XCTAssertTrue(model.operating.precisionPanelOpen)
            XCTAssertFalse(model.operating.taskAid)
            XCTAssertNil(model.operating.arm?.target)
            XCTAssertEqual(model.operating.speed, .fine)
            model.selectSpeed(.coarse)
            model.buttonDown(.up)
            XCTAssertTrue(model.session.state.armMoving)
            tick(30)
            let update = wire.sent.last { $0["type"] as? String == "pose_update" }!
            let p = (update["payload"] as! [String: Any])["p_rel_m"] as! [Double]
            XCTAssertEqual(p[0], 0, accuracy: 1e-6)
            XCTAssertEqual(p[1], 0, accuracy: 1e-6)
            XCTAssertEqual(p[2], -0.0099, accuracy: 0.0001)
            model.buttonUp(.up)
            XCTAssertEqual(wire.count("pose_stop"), 1)
            acknowledgeStop()
            for (button, target) in [(ButtonID.close, GripperState.closed), (.open, .open)] {
                model.buttonDown(button)
                XCTAssertEqual(model.session.state.gripperMoving, target)
                model.buttonUp(button)
                XCTAssertNil(model.session.state.gripperMoving)
                XCTAssertFalse(model.link.armHeardAfterLastStop)
                let starts = wire.count("gripper_jog_start")
                let opposite: ButtonID = button == .close ? .open : .close
                model.buttonDown(opposite)
                XCTAssertNil(model.session.state.gripperMoving, "the previous jaw stop has not been confirmed")
                XCTAssertEqual(wire.count("gripper_jog_start"), starts)
                model.buttonUp(opposite)
                let sequence = wire.sent.last { $0["type"] as? String == "gripper_jog_start" }!["seq"] as! Int
                wire.server("ack", seq: sequence, ["seq": sequence, "status": "ok", "reason": "gripper_jog_stopped"])
                XCTAssertFalse(model.link.armHeardAfterLastStop, "confirmation still needs a fresh arm reading")
                wire.server(
                    "state",
                    [
                        "estop": false, "gripper": target == .open ? "open" : "closed",
                        "ee_pos": [0.0, -0.14, 0.16],
                    ])
                XCTAssertTrue(model.link.armHeardAfterLastStop)
            }
            XCTAssertEqual(wire.count("gripper_jog_start"), 2)
            XCTAssertEqual(wire.count("gripper_jog_stop"), 2)
            model.setPrecisionPanelOpen(false)
            XCTAssertEqual(model.operating.mode, mode)
            XCTAssertEqual(model.operating.speed, .coarse)
            XCTAssertEqual(UserDefaults.standard.string(forKey: AppModel.controlModeKey), persisted)
        }
    }

    func testHeldPhoneInputRefusesEntryAndPendingStopMustFinish() {
        bringUp()
        model.keyEvent(.upper, down: true)
        model.setPrecisionPanelOpen(true)
        XCTAssertFalse(model.operating.precisionPanelOpen)
        model.keyEvent(.upper, down: false)
        XCTAssertFalse(model.link.armHeardAfterLastStop)
        model.setPrecisionPanelOpen(true)
        XCTAssertFalse(model.operating.precisionPanelOpen)
        acknowledgeStop()
        model.setPrecisionPanelOpen(true)
        XCTAssertTrue(model.operating.precisionPanelOpen)
    }

    func testFineOwnsKeysTouchesAndDirectPhoneStartsUntilReleasedAfterClosing() {
        bringUp()
        model.setPrecisionPanelOpen(true)
        model.keyEvent(.upper, down: true)
        touch(1, .began)
        model.send(.holdArmStart)
        model.send(.wristStart)
        model.send(.gripperStart(.closed))
        model.startButtonTranslation()
        tick(10)
        XCTAssertEqual(wire.count("pose_start"), 0)
        XCTAssertEqual(wire.count("orient_start"), 0)
        XCTAssertEqual(wire.count("gripper_jog_start"), 0)
        XCTAssertNil(model.session.state.gripperMoving)
        model.setPrecisionPanelOpen(false)
        model.keyEvent(.upper, down: true)
        touch(1, .moved)
        tick(10)
        XCTAssertEqual(wire.count("pose_start"), 0)
        model.setPrecisionPanelOpen(true)
        XCTAssertFalse(model.operating.precisionPanelOpen)
        model.keyEvent(.upper, down: false)
        touch(1, .ended)
        model.keyEvent(.upper, down: true)
        XCTAssertEqual(wire.count("pose_start"), 1)
        model.keyEvent(.upper, down: false)
    }

    func testWrongSourceButtonCannotStartOrInterruptPhoneHold() {
        bringUp()
        model.buttonDown(.up)
        XCTAssertEqual(wire.count("pose_start"), 0)
        model.buttonUp(.up)
        model.keyEvent(.upper, down: true)
        model.buttonDown(.down)
        model.keyEvent(.upper, down: true)
        XCTAssertEqual(wire.count("pose_start"), 1)
        XCTAssertTrue(model.session.state.armMoving)
        XCTAssertEqual(wire.count("pose_stop"), 0)
        model.keyEvent(.upper, down: false)
        XCTAssertEqual(wire.count("pose_stop"), 1)
        model.buttonUp(.down)
        XCTAssertEqual(wire.count("pose_stop"), 1)
    }

    func testClosingEndsFineHoldExactlyOnceAndPreservesDeadButtonUntilRelease() {
        bringUp()
        model.setPrecisionPanelOpen(true)
        model.buttonDown(.down)
        tick(3)
        model.setPrecisionPanelOpen(false)
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertEqual(wire.count("pose_stop"), 1)
        acknowledgeStop()
        model.setPrecisionPanelOpen(true)
        XCTAssertFalse(model.operating.precisionPanelOpen)
        model.buttonUp(.down)
        XCTAssertEqual(wire.count("pose_stop"), 1)
        model.setPrecisionPanelOpen(true)
        XCTAssertTrue(model.operating.precisionPanelOpen)
        model.buttonDown(.up)
        XCTAssertEqual(wire.count("pose_start"), 2)
        model.buttonUp(.up)
    }

    func testBackgroundSettingsSlowLinkAndDisconnectClosePanelWithoutRestart() {
        let endings: [(String, (AppModel) -> Void)] = [
            ("background", { $0.activeChanged(false) }),
            ("settings", { $0.send(.openSettings) }),
            (
                "slow link",
                {
                    $0.session.state.commandsBlocked = true; $0.controller.sessionChanged()
                }
            ),
            (
                "disconnect",
                {
                    $0.session.state.connected = false; $0.controller.sessionChanged()
                }
            ),
        ]
        for (name, end) in endings {
            bringUp()
            model.setPrecisionPanelOpen(true)
            model.buttonDown(.up)
            end(model)
            XCTAssertFalse(model.operating.precisionPanelOpen, name)
            XCTAssertFalse(model.session.state.armMoving, name)
            XCTAssertEqual(wire.count("pose_stop"), 1, name)
            model.activeChanged(true)
            model.buttonUp(.up)
            tick(2)
            XCTAssertEqual(wire.count("pose_start"), 1, name)
        }
    }

    func testStopBandRemainsAvailableAndClosesFinePanel() {
        bringUp()
        model.setPrecisionPanelOpen(true)
        model.buttonDown(.up)
        let band = model.operating.layout!.bottomBand
        touch(9, .began, x: band.x + band.width / 2, y: band.y + band.height / 2)
        XCTAssertTrue(model.session.state.emergencyStop)
        XCTAssertFalse(model.operating.precisionPanelOpen)
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertEqual(wire.count("estop"), 1)
        model.buttonUp(.up)
        tick(2)
        XCTAssertEqual(wire.count("pose_start"), 1)
    }

    func testResetCountdownRefusesEntry() {
        bringUp()
        let band = model.operating.layout!.topBand
        touch(9, .began, x: 200, y: band.maxY - 20)
        model.setPrecisionPanelOpen(true)
        XCTAssertFalse(model.operating.precisionPanelOpen, "the pending band touch still owns its input")
        tick(10)
        XCTAssertNotNil(model.operating.resetCountdown)
        model.setPrecisionPanelOpen(true)
        XCTAssertFalse(model.operating.precisionPanelOpen)
        touch(9, .ended, x: 200, y: band.maxY - 20)
    }

    // MARK: The entry while a move nobody holds runs

    /// The upper key's press starts the follow and its release leaves it running.
    private func latch(line: UInt = #line) {
        clock += 100
        model.keyEvent(.upper, down: true)
        clock += 100
        model.keyEvent(.upper, down: false)
        XCTAssertTrue(model.session.state.armMoving, line: line)
        guard case .latched? = model.controller.arbiter.engagement else {
            return XCTFail("not latched", line: line)
        }
    }

    private func heard(since mark: Int) -> [CueKey] { model.cueLog.dropFirst(mark).map(\.event) }

    func testEntryStopsALatchedFollowAndOpensOnceTheStopIsHeard() {
        bringUp(lock: .pressPress)
        latch()
        let mark = model.cueLog.count
        model.setPrecisionPanelOpen(true)
        XCTAssertEqual(wire.count("pose_stop"), 1, "one press stops the follow")
        XCTAssertNil(model.controller.arbiter.engagement)
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertFalse(model.operating.precisionPanelOpen, "not before the stop is heard")
        XCTAssertEqual(heard(since: mark), [.drive(.stoppedByYou)])
        tick(3)
        XCTAssertFalse(model.operating.precisionPanelOpen)
        acknowledgeStop()
        tick()
        XCTAssertTrue(model.operating.precisionPanelOpen, "opens with no second press")
        XCTAssertEqual(model.operating.speed, .fine)
        XCTAssertEqual(wire.count("pose_stop"), 1)
        XCTAssertEqual(heard(since: mark), [.drive(.stoppedByYou)], "no NO and no Let go first")
    }

    func testEntryOpensOnAFreshArmReadingAfterTheStopWithoutItsAck() {
        bringUp(lock: .pressPress)
        latch()
        model.setPrecisionPanelOpen(true)
        tick(26)
        XCTAssertFalse(model.operating.precisionPanelOpen)
        wire.server("state", ["estop": false, "gripper": "open", "ee_pos": [0.0, -0.14, 0.16]])
        XCTAssertTrue(model.link.armHeardAfterLastStop, "the link's own rule after 0.8 s")
        tick()
        XCTAssertTrue(model.operating.precisionPanelOpen)
    }

    func testEntryGivesUpWithNoWhenTheStopIsNotHeardInTime() {
        bringUp(lock: .pressPress)
        latch()
        model.setPrecisionPanelOpen(true)
        let mark = model.cueLog.count
        tick(44)
        XCTAssertFalse(model.operating.precisionPanelOpen)
        XCTAssertEqual(heard(since: mark), [], "still waiting at 1.45 s")
        tick(3)
        XCTAssertEqual(heard(since: mark), [.refused(.deadInput)])
        acknowledgeStop()
        tick(5)
        XCTAssertFalse(model.operating.precisionPanelOpen, "a late stop opens nothing")
        XCTAssertEqual(wire.count("pose_stop"), 1)
    }

    func testAnythingElseWhileWaitingDropsTheEntry() {
        let interruptions: [(String, (PrecisionControlTests) -> Void)] = [
            (
                "STOP",
                { test in
                    let band = test.model.operating.layout!.bottomBand
                    test.touch(9, .began, x: band.x + band.width / 2, y: band.y + band.height / 2)
                }
            ),
            (
                "background",
                { test in
                    test.model.activeChanged(false)
                    test.model.activeChanged(true)
                }
            ),
            ("settings", { $0.model.send(.openSettings) }),
            (
                "slow link",
                { test in
                    test.model.session.state.commandsBlocked = true
                    test.model.controller.sessionChanged()
                }
            ),
            (
                "disconnect",
                { test in
                    test.model.session.state.connected = false
                    test.model.controller.sessionChanged()
                }
            ),
            ("scene reset", { $0.model.controller.sceneReset() }),
            ("mode change", { $0.model.controlMode = .keyTurns }),
            (
                "a key",
                { test in
                    test.clock += 50
                    test.model.keyEvent(.lower, down: true)
                    test.clock += 50
                    test.model.keyEvent(.lower, down: false)
                }
            ),
            (
                "a touch",
                { test in
                    test.touch(5, .began)
                    test.clock += 50
                    test.touch(5, .ended)
                }
            ),
            (
                "the reset band",
                { test in
                    let band = test.model.operating.layout!.topBand
                    test.touch(6, .began, x: 200, y: band.maxY - 20)
                    test.clock += 50
                    test.touch(6, .ended, x: 200, y: band.maxY - 20)
                }
            ),
        ]
        for (name, interrupt) in interruptions {
            bringUp(lock: .pressPress)
            latch()
            model.setPrecisionPanelOpen(true)
            XCTAssertFalse(model.operating.precisionPanelOpen, name)
            interrupt(self)
            if model.session.route == .s6 { model.send(.settingsDone) }
            acknowledgeStopIfOwed()
            tick(5)
            XCTAssertFalse(model.operating.precisionPanelOpen, "\(name): dropped, never opened later")
            tick(50)
            XCTAssertFalse(model.operating.precisionPanelOpen, "\(name): not after the wait either")
        }
    }

    /// Answers the newest arm start's stop, if one is outstanding, with its ack and a fresh reading.
    private func acknowledgeStopIfOwed() {
        guard model.session.state.connected, !model.link.armHeardAfterLastStop,
            let start = wire.sent.last(where: { $0["type"] as? String == "pose_start" })?["seq"] as? Int
        else { return }
        wire.server("ack", seq: start, ["seq": start, "status": "ok", "reason": "pose_stopped"])
        wire.server(
            "state", ["estop": model.session.state.emergencyStop, "gripper": "open", "ee_pos": [0.0, -0.14, 0.16]])
    }

    func testEntryStillRefusesAHeldFollowAndLeavesItRunning() {
        bringUp()
        model.keyEvent(.upper, down: true)
        let mark = model.cueLog.count
        model.setPrecisionPanelOpen(true)
        XCTAssertFalse(model.operating.precisionPanelOpen)
        XCTAssertTrue(model.session.state.armMoving, "the held follow goes on")
        XCTAssertEqual(wire.count("pose_stop"), 0)
        XCTAssertEqual(heard(since: mark), [.refused(.letGoFirst)])
        model.keyEvent(.upper, down: false)
        XCTAssertEqual(wire.count("pose_stop"), 1)
    }

    func testEntryStillRefusesTheJawsAndLeavesThemMoving() {
        bringUp()
        model.keyEvent(.lower, down: true)
        XCTAssertEqual(model.session.state.gripperMoving, .closed)
        model.setPrecisionPanelOpen(true)
        XCTAssertFalse(model.operating.precisionPanelOpen)
        XCTAssertEqual(model.session.state.gripperMoving, .closed)
        model.keyEvent(.lower, down: false)
    }

    func testSecondPressWhileWaitingIsSilentAndOpensOnce() {
        bringUp(lock: .pressPress)
        latch()
        model.setPrecisionPanelOpen(true)
        let mark = model.cueLog.count
        model.setPrecisionPanelOpen(true)
        XCTAssertEqual(heard(since: mark), [])
        acknowledgeStop()
        tick()
        XCTAssertTrue(model.operating.precisionPanelOpen)
        XCTAssertEqual(wire.count("pose_stop"), 1)
    }
}

final class PrecisionPracticeTests: XCTestCase {
    private var saved: [String: Any] = [:]
    private let keys = [AppModel.controlModeKey, AppModel.taskAidKey, AppModel.assistKey, AppModel.lockChoiceKey]

    override func setUp() {
        super.setUp()
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
    }

    override func tearDown() {
        for key in keys { UserDefaults.standard.set(saved[key], forKey: key) }
        super.tearDown()
    }

    func testWithoutARobotTheEntryStopsTheFollowAndOpensAtOnce() {
        var clock = 10_000
        UserDefaults.standard.set(false, forKey: AppModel.taskAidKey)
        let model = AppModel(
            start: .p4, haptics: NoHaptics(), sounds: SpySounds(), speech: SpySpeech(),
            pose: { TestPose.portrait }, liveLink: false, nowMs: { clock },
            inputClock: { Double(clock) / 1000 }, assistOn: true, lockChoice: .pressPress
        )
        model.controlMode = .screenTurns
        model.surfaceChanged(width: 375, height: 667, safeTop: 20, safeBottom: 0)
        clock += 100
        model.keyEvent(.upper, down: true)
        clock += 100
        model.keyEvent(.upper, down: false)
        guard case .latched? = model.controller.arbiter.engagement else { return XCTFail("not latched") }
        model.setPrecisionPanelOpen(true)
        XCTAssertNil(model.controller.arbiter.engagement)
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertTrue(model.operating.precisionPanelOpen, "no server to wait for")
    }
}
