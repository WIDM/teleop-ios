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

/// When every hold ends, the controller tells the input rules why, as far as the app knows it, and a follow nobody
/// holds is heard ending for that reason: a stop or a lost link has played its own cue, a refused start has played its
/// refusal, and the slow link, leaving the operating screen, leaving the app and the camera stopping are named. A
/// reason nobody gives is heard as "Stopped here." alone, never taken for one already told. With a hold tied to an
/// input the reason changes nothing anyone hears, so these run on a follow latched by a press of the upper key, chosen
/// through the model.
final class AssistControllerTests: XCTestCase {
    private var control: ReasonTestTransport?
    private var clock = 10_000
    private var model: AppModel!
    private var savedMode: String?
    /// The cue log's length when the follow latched.
    private var mark = 0

    override func setUp() {
        super.setUp()
        savedMode = UserDefaults.standard.string(forKey: AppModel.controlModeKey)
    }

    /// Both of the aids' settings are removed, never put back: a launch argument shadows the saved value, so a value
    /// read here and written back could be the argument's, saved for good. The models here are given the aids and
    /// save nothing; this keeps it so if a test ever sets them.
    override func tearDown() {
        UserDefaults.standard.set(savedMode, forKey: AppModel.controlModeKey)
        UserDefaults.standard.removeObject(forKey: AppModel.assistKey)
        UserDefaults.standard.removeObject(forKey: AppModel.lockChoiceKey)
        model = nil
        control = nil
        super.tearDown()
    }

    /// A model on a real server, in scheme A, with lock variant 1, whose link is not open yet.
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
            inputClock: { [unowned self] in Double(clock) / 1000 },
            assistOn: true, lockChoice: .pressPress
        )
        model.controlMode = .screenTurns
        mark = model.cueLog.count
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

    /// The upper key's press starts the follow, and its release leaves it running.
    private func latchTheArm(line: UInt = #line) {
        clock += 100
        model.keyEvent(.upper, down: true)
        clock += 100
        model.keyEvent(.upper, down: false)
        XCTAssertTrue(model.session.state.armMoving, line: line)
        guard case .latched? = model.controller.arbiter.engagement else {
            return XCTFail("not latched: \(String(describing: model.controller.arbiter.engagement))", line: line)
        }
        XCTAssertEqual(model.cueLog.last?.event, .drive(.latched), line: line)
        mark = model.cueLog.count
    }

    /// The endings of a follow heard since it latched.
    private var endingsHeard: [DriveCue] {
        model.cueLog.dropFirst(mark).compactMap { entry -> DriveCue? in
            guard case .drive(let cue) = entry.event, cue != .latched else { return nil }
            return cue
        }
    }

    private func heardSinceTheLatch(_ event: CueKey) -> Bool {
        model.cueLog.dropFirst(mark).contains { $0.event == event }
    }

    /// The follow ended, the session's hold with it, and exactly this ending was heard: none when someone else has
    /// told it.
    private func assertEnded(hearing ending: DriveEnd?, _ message: String, line: UInt = #line) {
        XCTAssertEqual(endingsHeard, ending.map { [.ended($0)] } ?? [], message, line: line)
        XCTAssertNil(model.controller.arbiter.engagement, message, line: line)
        XCTAssertFalse(model.session.state.armMoving, message, line: line)
    }

    func testSessionChangedNamesTheReason() {
        bringUp()
        latchTheArm()
        model.send(.stop)
        assertEnded(hearing: nil, "STOP: its ALARM has played")
        XCTAssertTrue(
            model.cueLog.dropFirst(mark).contains {
                if case .emergencyStop = $0.event { return true }
                return false
            }, "\(model.cueLog)")

        bringUp()
        latchTheArm()
        control?.onClose?()
        assertEnded(hearing: nil, "a lost link: its sound and words have played")
        XCTAssertTrue(heardSinceTheLatch(.linkLost(holdEngaged: true)))

        // The session is connected but no link is open, so the link cannot start the hold the session took.
        makeModel()
        model.session.state.markConnected()
        clock += 100
        model.keyEvent(.upper, down: true)
        assertEnded(hearing: nil, "a refused start: its refusal has played")
        XCTAssertTrue(heardSinceTheLatch(.refused(.noLink)))

        bringUp()
        latchTheArm()
        model.send(.linkLatency(ms: 500))
        XCTAssertTrue(model.session.state.armMoving, "one slow sample is not a slow link")
        XCTAssertEqual(endingsHeard, [])
        model.send(.linkLatency(ms: 500))
        XCTAssertTrue(model.session.state.commandsBlocked)
        assertEnded(hearing: .slowLink, "a slow link")

        bringUp()
        latchTheArm()
        model.send(.openSettings)
        XCTAssertEqual(model.session.route, .s6)
        assertEnded(hearing: .leftScreen, "leaving the operating screen")

        bringUp()
        latchTheArm()
        model.send(.holdArmEnd)
        assertEnded(hearing: .unnamed, "the session's hold ended and nobody said why")
    }

    func testLeavingTheAppAndTheCameraNameTheirReasons() {
        bringUp()
        latchTheArm()
        model.activeChanged(false)
        assertEnded(hearing: .appLeft, "the app left the active state")
        model.activeChanged(true)
        XCTAssertEqual(endingsHeard, [.ended(.appLeft)], "coming back ends nothing more")

        bringUp()
        latchTheArm()
        model.controller.cameraInterrupted(true)
        assertEnded(hearing: .cameraStopped, "the camera stopped")
    }

    /// A press whose start the link could not carry latches nothing the operator hears: the refusal is the one cue,
    /// and the latch cue that came with the start is not played.
    func testTheLatchCueIsSkippedWhenTheStartWasRefused() {
        // The session is connected but no link is open, so the link cannot start the hold the session took.
        makeModel()
        model.session.state.markConnected()
        clock += 100
        model.keyEvent(.upper, down: true)
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertNil(model.controller.arbiter.engagement)
        XCTAssertEqual(model.cueLog.dropFirst(mark).map(\.event), [.refused(.noLink)])
        XCTAssertFalse(model.link.holdIsLoose)
        clock += 100
        model.keyEvent(.upper, down: false)
        XCTAssertEqual(model.cueLog.dropFirst(mark).map(\.event), [.refused(.noLink)], "the release adds nothing")
    }

    /// The operator's own ending is carried to the model as such.
    func testAPressThatEndsTheFollowIsHeardAsStoppedByYou() {
        bringUp()
        latchTheArm()
        clock += 500
        model.keyEvent(.lower, down: true)
        XCTAssertEqual(endingsHeard, [.stoppedByYou])
        XCTAssertNil(model.controller.arbiter.engagement)
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertNil(model.session.state.gripperMoving, "the press that ended it moved nothing")
        clock += 100
        model.keyEvent(.lower, down: false)
        XCTAssertEqual(endingsHeard, [.stoppedByYou])
    }
}
