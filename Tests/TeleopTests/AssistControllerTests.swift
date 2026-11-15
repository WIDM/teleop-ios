import simd
import TeleopCore
import XCTest
@testable import Teleop

private final class ReasonTestTransport: LinkTransport {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?

    func open() {}
    func close() {}
    func send(_ text: String) {}

    func server(_ type: String, _ payload: [String: Any] = [:]) {
        let message: [String: Any] = ["v": 1, "type": type, "ts": 0, "seq": 0, "payload": payload]
        onText?(String(data: try! JSONSerialization.data(withJSONObject: message), encoding: .utf8)!)
    }
}

/// When every hold ends, the controller tells the input rules why, as far as the app knows it: a stop or a lost link
/// has played its own cue, a refused start has played its refusal, and the slow link, leaving the operating screen,
/// leaving the app and the camera stopping are named. A reason nobody gives is never taken for one already told.
final class AssistControllerTests: XCTestCase {
    private var control: ReasonTestTransport?
    private var clock = 10_000
    private var model: AppModel!
    private var savedMode: String?

    override func setUp() {
        super.setUp()
        savedMode = UserDefaults.standard.string(forKey: AppModel.controlModeKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(savedMode, forKey: AppModel.controlModeKey)
        model = nil
        control = nil
        super.tearDown()
    }

    /// A model on a real server, in scheme A, whose link is not open yet.
    private func makeModel() {
        clock = 10_000
        control = nil
        model = AppModel(
            start: .p4, haptics: NoHaptics(), sounds: SpySounds(), speech: SpySpeech(),
            pose: { TestPose.portrait }, liveLink: true,
            makeTransport: { [unowned self] _ in
                let made = ReasonTestTransport()
                control = made
                return made
            },
            makeObserverTransport: { _ in ReasonTestTransport() },
            nowMs: { [unowned self] in clock },
            inputClock: { [unowned self] in Double(clock) / 1000 }
        )
        model.controlMode = .screenTurns
    }

    /// Standby with the link up.
    private func bringUp() {
        makeModel()
        model.session.state.serverAddress = "100.64.0.1:8765"
        model.connect()
        control?.server("welcome")
        control?.server("state", ["estop": false, "gripper": "open"])
        XCTAssertTrue(model.session.state.connected)
    }

    /// The upper key moves the arm.
    private func holdTheArm() {
        clock += 100
        model.keyEvent(.upper, down: true)
        XCTAssertTrue(model.session.state.armMoving)
        XCTAssertEqual(model.controller.engagedHold, .translation)
    }

    private func assertEnded(_ reason: Interruption, _ message: String, line: UInt = #line) {
        XCTAssertEqual(model.controller.lastInterruption, reason, message, line: line)
        XCTAssertNil(model.controller.arbiter.engagement, message, line: line)
        XCTAssertFalse(model.session.state.armMoving, message, line: line)
    }

    func testSessionChangedNamesTheReason() {
        bringUp()
        holdTheArm()
        model.send(.stop)
        assertEnded(.announced, "STOP: its ALARM has played")

        bringUp()
        holdTheArm()
        control?.onClose?()
        assertEnded(.announced, "a lost link: its sound and words have played")

        // The session is connected but no link is open, so the link cannot start the hold the session took.
        makeModel()
        model.session.state.markConnected()
        clock += 100
        model.keyEvent(.upper, down: true)
        assertEnded(.startRefused, "a refused start: its refusal has played")
        XCTAssertTrue(model.cueLog.contains { $0.event == .refused(.noLink) })

        bringUp()
        holdTheArm()
        model.send(.linkLatency(ms: 500))
        XCTAssertTrue(model.session.state.armMoving, "one slow sample is not a slow link")
        model.send(.linkLatency(ms: 500))
        XCTAssertTrue(model.session.state.commandsBlocked)
        assertEnded(.slowLink, "a slow link")

        bringUp()
        holdTheArm()
        model.send(.openSettings)
        XCTAssertEqual(model.session.route, .s6)
        assertEnded(.leftScreen, "leaving the operating screen")

        bringUp()
        holdTheArm()
        model.send(.holdArmEnd)
        assertEnded(.unnamed, "the session's hold ended and nobody said why")
    }

    func testLeavingTheAppAndTheCameraNameTheirReasons() {
        bringUp()
        holdTheArm()
        model.activeChanged(false)
        assertEnded(.appLeft, "the app left the active state")
        model.activeChanged(true)
        XCTAssertEqual(model.controller.lastInterruption, .appLeft, "coming back ends nothing")

        bringUp()
        holdTheArm()
        model.controller.cameraInterrupted(true)
        assertEnded(.cameraStopped, "the camera stopped")
    }
}
