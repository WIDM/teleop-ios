import simd
import TeleopCore
import XCTest
@testable import Teleop

private final class ReadinessTransport: LinkTransport {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    func open() {}
    func close() {}
    func send(_ text: String) {}
    func state(_ payload: [String: Any], at time: Int) {
        let packet: [String: Any] = ["v": 1, "type": "state", "ts": time, "seq": 0, "payload": payload]
        onText?(String(data: try! JSONSerialization.data(withJSONObject: packet), encoding: .utf8)!)
    }
    func welcome() {
        onText?("{\"v\":1,\"type\":\"welcome\",\"ts\":0,\"seq\":0,\"payload\":{}}")
    }
}

private final class DelayedReadinessSpeech: SpeechPlaying {
    var onFinished: ((Int) -> Void)?
    var onStarted: ((Int) -> Void)?
    var submitted: [Int] = []
    var stopped: [Int] = []
    func speak(_ text: String, language: String, interrupt: Bool, id: Int) { submitted.append(id) }
    func stop(id: Int) { stopped.append(id) }
}

final class ReadinessSpeechTests: XCTestCase {
    private var savedLanguage = L10n.language

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.language
        L10n.language = .en
    }

    override func tearDown() {
        L10n.language = savedLanguage
        super.tearDown()
    }

    func testQueuedReadinessIsInvalidatedByEachOperatingTransition() {
        let transitions: [(String, (AppModel) -> Void)] = [
            ("STOP", { $0.send(.stop) }),
            (
                "disconnect",
                {
                    $0.session.state.markDisconnected(); $0.inputsChanged()
                }
            ),
            ("settings", { $0.send(.openSettings) }),
            ("background", { $0.activeChanged(false) }),
            ("camera loss", { $0.controller.cameraInterrupted(true) }),
            ("arm hold", { $0.send(.holdArmStart) }),
            (
                "slow link",
                {
                    $0.session.state.commandsBlocked = true; $0.inputsChanged()
                }
            ),
        ]
        for (name, invalidate) in transitions {
            let speech = SpySpeech()
            speech.holds = true
            let model = AppModel(
                start: .p4, haptics: NoHaptics(), sounds: SpySounds(), speech: speech,
                pose: { TestPose.portrait }, liveLink: false, nowMs: { 1000 })
            model.controlMode = .screenTurns
            model.raise(.takeDiscarded)
            model.raise(.ready)
            XCTAssertEqual(speech.spoken.count, 1, name)
            invalidate(model)
            for _ in 0..<5 { speech.finish() }
            XCTAssertFalse(speech.spoken.contains("Controls available."), name)
        }
    }

    func testBriefTrackingLossCannotResurrectQueuedAvailability() {
        let speech = SpySpeech()
        speech.holds = true
        var pose: simd_float4x4? = TestPose.portrait
        let wire = ReadinessTransport()
        let model = AppModel(
            start: .p4, haptics: NoHaptics(), sounds: SpySounds(), speech: speech,
            pose: { pose }, liveLink: true, makeTransport: { _ in wire },
            makeObserverTransport: { _ in ReadinessTransport() }, nowMs: { 1000 })
        model.controlMode = .screenTurns
        model.session.state.serverAddress = "127.0.0.1:8765"
        model.connect()
        wire.welcome()
        wire.state(["estop": false, "gripper": "open", "ee_pos": [0.0, -0.14, 0.16]], at: 1000)
        XCTAssertTrue(model.session.state.connected)
        for _ in 0..<5 { speech.finish() }
        speech.spoken = []
        model.raise(.takeDiscarded)
        model.raise(.ready)
        XCTAssertEqual(speech.spoken.count, 1)
        pose = nil
        model.poseFrame(nil, at: 1.0)
        pose = TestPose.portrait
        model.poseFrame(pose, at: 1.01)
        speech.finish()
        XCTAssertFalse(speech.spoken.contains("Controls available."))
        model.raise(.ready)
        XCTAssertEqual(speech.spoken.last, "Controls available.")
    }

    func testSettingsRoundTripDoesNotResurrectOldReadiness() {
        let speech = SpySpeech()
        speech.holds = true
        let model = AppModel(start: .p4, haptics: NoHaptics(), sounds: SpySounds(), speech: speech, liveLink: false)
        model.raise(.takeDiscarded)
        model.raise(.ready)
        model.send(.openSettings)
        model.send(.settingsDone)
        speech.finish()
        XCTAssertFalse(speech.spoken.contains("Controls available."))
        model.raise(.ready)
        XCTAssertEqual(speech.spoken.last, "Controls available.")
    }

    func testAReadinessAlreadySubmittedToSpeechIsCancelledOnBackground() {
        let speech = SpySpeech()
        speech.holds = true
        let model = AppModel(start: .p4, haptics: NoHaptics(), sounds: SpySounds(), speech: speech, liveLink: false)
        model.raise(.ready)
        XCTAssertEqual(speech.speaking.count, 1)
        model.activeChanged(false)
        XCTAssertTrue(speech.speaking.isEmpty)
        model.raise(.takeSaved(count: 4))
        XCTAssertEqual(speech.spoken.last, "Saved. 4.")
    }

    func testNoCameraIsRequiredForPrecisionAvailability() {
        let speech = SpySpeech()
        let model = AppModel(
            start: .p4, haptics: NoHaptics(), sounds: SpySounds(), speech: speech,
            pose: { nil }, liveLink: false)
        model.controller.cameraInterrupted(true)
        model.setPrecisionPanelOpen(true)
        model.raise(.ready)
        XCTAssertEqual(speech.spoken.last, "Controls available.")
    }
    func testResetStateInvalidatesQueuedReadinessBeforeDisplayRefresh() {
        let speech = SpySpeech()
        speech.holds = true
        let wire = ReadinessTransport()
        var clock = 1000
        let model = AppModel(
            start: .p4, haptics: NoHaptics(), sounds: SpySounds(), speech: speech,
            pose: { TestPose.portrait }, liveLink: true, makeTransport: { _ in wire },
            makeObserverTransport: { _ in ReadinessTransport() }, nowMs: { clock })
        model.session.state.serverAddress = "127.0.0.1:8765"
        model.connect()
        wire.welcome()
        wire.state(["estop": false, "gripper": "open", "ee_pos": [0.0, -0.14, 0.16]], at: 1000)
        for _ in 0..<5 { speech.finish() }
        speech.spoken = []
        model.raise(.takeDiscarded)
        model.raise(.ready)
        clock = 1100
        wire.state(["estop": false, "ik": "resetting", "ee_pos": [0.0, -0.14, 0.16]], at: clock)
        XCTAssertEqual(model.operating.state, .wait(.resetting))
        speech.finish()
        XCTAssertFalse(speech.spoken.contains("Controls available."))
        clock = 1200
        wire.state(["estop": false, "ik": "ok", "ee_pos": [0.0, -0.14, 0.16]], at: clock)
        model.raise(.ready)
        for _ in 0..<5 { speech.finish() }
        XCTAssertTrue(speech.spoken.contains("Controls available."))
    }

    func testWelcomeAnnouncesCurrentAvailabilityBeforeTheDisplayCatchesUp() {
        for route in [Route.p4, .s1] {
            let speech = SpySpeech()
            let wire = ReadinessTransport()
            let model = AppModel(
                start: route, haptics: NoHaptics(), sounds: SpySounds(), speech: speech,
                pose: { TestPose.portrait }, liveLink: true, makeTransport: { _ in wire },
                makeObserverTransport: { _ in ReadinessTransport() })
            model.session.state.serverAddress = "127.0.0.1:8765"
            model.connect()
            XCTAssertFalse(model.session.state.connected)
            wire.welcome()
            XCTAssertFalse(model.session.state.connected, "welcome without robot state is not a completed connection")
            wire.state(["estop": false, "gripper": "open", "ee_pos": [0.0, -0.14, 0.16]], at: 1000)
            XCTAssertTrue(model.session.state.connected)
            XCTAssertEqual(speech.spoken.filter { $0 == "Controls available." }.count, 1, "\(route)")
        }
    }

    func testControlDisconnectInvalidatesReadinessThroughTheRealCallback() {
        let speech = SpySpeech()
        let wire = ReadinessTransport()
        let model = AppModel(
            start: .p4, haptics: NoHaptics(), sounds: SpySounds(), speech: speech,
            pose: { TestPose.portrait }, liveLink: true, makeTransport: { _ in wire },
            makeObserverTransport: { _ in ReadinessTransport() })
        model.session.state.serverAddress = "127.0.0.1:8765"
        model.connect()
        wire.welcome()
        wire.state(["estop": false, "gripper": "open", "ee_pos": [0.0, -0.14, 0.16]], at: 1000)
        XCTAssertEqual(speech.spoken, ["Controls available."])
        speech.spoken = []
        speech.holds = true
        model.raise(.takeSaved(count: 2))
        model.raise(.ready)
        wire.onClose?()
        XCTAssertFalse(model.session.state.connected)
        for _ in 0..<5 { speech.finish() }
        model.raise(.ready)
        XCTAssertFalse(speech.spoken.contains("Controls available."))
        XCTAssertTrue(speech.spoken.contains("Link lost."))
    }

    func testReadyStartingAfterTimeoutIsNotAcceptedAndCannotCancelNewAlarm() {
        for alarmAfterTimeout in [false, true] {
            var clock = 0
            let speech = DelayedReadinessSpeech()
            let cues = CuePlayer(haptics: NoHaptics(), sounds: SpySounds(), speech: speech, nowMs: { clock })
            cues.isReady = { true }
            var log: [String] = []
            cues.onSpeechLog = { log.append($0) }
            cues.raise(.ready)
            let obsolete = speech.submitted[0]
            clock = 15000
            cues.tick()
            XCTAssertEqual(speech.stopped, [obsolete])
            if alarmAfterTimeout { cues.raise(.emergencyStop(.button, takeDiscarded: false)) }
            let stops = speech.stopped
            speech.onStarted?(obsolete)
            speech.onFinished?(obsolete)
            XCTAssertEqual(speech.stopped, stops, "a late callback cannot cancel a newer utterance")
            XCTAssertFalse(log.contains { $0.contains("speech start id=\(obsolete) ") })
            if alarmAfterTimeout {
                let alarm = speech.submitted.last!
                speech.onStarted?(alarm)
                XCTAssertTrue(log.contains { $0.contains("speech start id=\(alarm) ") })
            }
        }
    }

}
