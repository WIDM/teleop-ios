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

    private func bringUp(_ mode: ControlMode = .screenTurns, tracking: Bool = true) {
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
            assistOn: false, lockChoice: .off
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
}
