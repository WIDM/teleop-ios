import simd
import TeleopCore
import XCTest
@testable import Teleop

/// A socket that keeps what the app sends and lets the test speak for the server.
private final class LooseLinkTransport: LinkTransport {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    var sent: [[String: Any]] = []

    func open() {}
    func close() {}
    func send(_ text: String) {
        sent.append(try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])
    }

    var types: [String] { sent.map { $0["type"] as! String } }

    /// Every message sent, each as one line of JSON with its keys in order, so two runs can be compared.
    var lines: [String] {
        sent.map {
            String(data: try! JSONSerialization.data(withJSONObject: $0, options: .sortedKeys), encoding: .utf8)!
        }
    }

    func server(_ type: String, seq: Int = 0, _ payload: [String: Any] = [:]) {
        let message: [String: Any] = ["v": 1, "type": type, "ts": 0, "seq": seq, "payload": payload]
        onText?(String(data: try! JSONSerialization.data(withJSONObject: message), encoding: .utf8)!)
    }
}

/// The link and a follow nobody holds, against a scripted server. A follow latched by a press of the upper key keeps
/// streaming the phone after the key is released. Every way the link ends it is heard once, as the follow's own
/// ending ("Stopped here." and why), and the input rules then add nothing; a refusal the alarm tells is told by the
/// alarm alone. A slow link is named by the input rules, never by a refusal. A hold someone holds is told as in
/// version 1.0.1.
final class AssistLinkTests: XCTestCase {
    private var transport: LooseLinkTransport!
    private var position: SIMD3<Float>? = .zero
    private var clock = 10_000
    private var model: AppModel!
    private var felt = SpyHaptics()
    private var speech = SpySpeech()
    private var savedLanguage = L10n.language
    private var savedMode: String?
    /// The cue log's length when the follow latched.
    private var mark = 0

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.language
        L10n.language = .en
        savedMode = UserDefaults.standard.string(forKey: AppModel.controlModeKey)
    }

    /// Both of the aids' settings are removed, never put back: a launch argument shadows the saved value, so a value
    /// read here and written back could be the argument's, saved for good. The models here are given the aids and
    /// save nothing; this keeps it so if a test ever sets them.
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppModel.assistKey)
        UserDefaults.standard.removeObject(forKey: AppModel.lockChoiceKey)
        UserDefaults.standard.set(savedMode, forKey: AppModel.controlModeKey)
        L10n.language = savedLanguage
        model = nil
        transport = nil
        super.tearDown()
    }

    /// Standby on the real server in scheme A with the link up, the aids given to the model without saving them, and
    /// nothing felt or heard yet.
    private func bringUp(assistOn: Bool = true, lock: LockChoice = .pressPress) {
        position = .zero
        clock = 10_000
        felt = SpyHaptics()
        speech = SpySpeech()
        model = AppModel(
            start: .p4, haptics: felt, sounds: SpySounds(), speech: speech,
            pose: { [unowned self] in position.map { TestPose.portrait(at: $0) } },
            liveLink: true,
            makeTransport: { [unowned self] _ in
                let made = LooseLinkTransport()
                transport = made
                return made
            },
            makeObserverTransport: { _ in LooseLinkTransport() },
            nowMs: { [unowned self] in clock },
            inputClock: { [unowned self] in Double(clock) / 1000 },
            clientName: "teleop-ios/1.0.0 (7)",
            assistOn: assistOn, lockChoice: lock
        )
        model.controlMode = .screenTurns
        model.session.state.serverAddress = "100.64.0.1:8765"
        // Exact offsets: the hand's movement is the command.
        model.session.state.setSmoothing(0)
        model.connect()
        transport.server("welcome")
        transport.server("state", ["estop": false, "gripper": "closed"])
        felt.felt = []
        speech.spoken = []
        mark = model.cueLog.count
    }

    /// A press and release of the upper key: the follow stays latched.
    private func latch(line: UInt = #line) {
        clock += 100
        model.keyEvent(.upper, down: true)
        clock += 100
        model.keyEvent(.upper, down: false)
        XCTAssertTrue(model.session.state.armMoving, line: line)
        XCTAssertEqual(model.controller.arbiter.engagement, .latched(since: 10.1), line: line)
        XCTAssertTrue(model.link.holdIsLoose, line: line)
        XCTAssertEqual(model.cueLog.last?.event, .drive(.latched), line: line)
        mark = model.cueLog.count
    }

    /// One pose tick, 33 ms later.
    private func tick() {
        clock += 33
        model.link.tick()
    }

    /// Many ticks with a server that answers every probe, as a live one does.
    private func run(ticks: Int) {
        var answered = transport.sent.count
        for _ in 0..<ticks {
            tick()
            for message in transport.sent.dropFirst(answered) where message["type"] as? String == "test" {
                transport.server("test", seq: message["seq"] as! Int)
            }
            answered = transport.sent.count
        }
    }

    private func lastSeq(of type: String) -> Int {
        transport.sent.last { $0["type"] as? String == type }!["seq"] as! Int
    }

    /// The server's final answer for the newest translation hold.
    private func serverAnswers(_ status: String, _ reason: String) {
        let start = lastSeq(of: "pose_start")
        transport.server("ack", seq: start, ["seq": start, "status": status, "reason": reason])
    }

    /// Everything heard since the follow latched.
    private var heard: [CueKey] { model.cueLog.dropFirst(mark).map(\.event) }

    /// The endings of the follow heard since it latched.
    private var endings: [DriveCue] {
        heard.compactMap { key -> DriveCue? in
            guard case .drive(let cue) = key, cue != .latched else { return nil }
            return cue
        }
    }

    /// The follow, the session's hold and the link's hold are over.
    private func assertOver(_ what: String, line: UInt = #line) {
        XCTAssertNil(model.controller.arbiter.engagement, what, line: line)
        XCTAssertFalse(model.session.state.armMoving, what, line: line)
        XCTAssertFalse(model.link.holdIsLoose, what, line: line)
    }

    func testALatchedFollowStreamsThePhoneAfterTheRelease() throws {
        bringUp()
        latch()
        XCTAssertEqual(transport.types, ["hello", "pose_start"], "the release sent no stop")
        position = SIMD3(0.01, 0, -0.02)
        tick()
        XCTAssertTrue(model.session.state.armMoving)
        XCTAssertEqual(transport.types.last, "pose_update")
        let update = try XCTUnwrap(transport.sent.last?["payload"] as? [String: Any])
        // 1 cm right and 2 cm forward (ARKit forward is −z), as the server wants them.
        XCTAssertEqual(update["p_rel_m"] as? [Double], [-0.01, -0.02, 0])
        XCTAssertEqual(endings, [])
    }

    /// Each way the link ends a follow nobody holds: the tracking it needs lost, the phone too fast, a re-sent start
    /// the server never finished, one it could not take, and every answer the server can give a running hold before
    /// and after GO. Each is heard exactly once as the follow's own ending, never as a let-go or a refusal, and the
    /// input rules add none of their own, so the link told them it had told the operator.
    func testEveryLinkEndingOfALooseHoldEmitsOneDriveCueAndRecordsAnnounced() {
        let trackingLost: (AssistLinkTests) -> Void = { test in
            test.position = nil
            test.tick()
        }
        let tooFast: (AssistLinkTests) -> Void = { test in
            test.run(ticks: 10)
            test.position = SIMD3(0.2, 0, 0)
            test.tick()
        }
        let neverFinished: (AssistLinkTests) -> Void = { test in
            test.sweepRight()
            test.run(ticks: 100)
        }
        let afterGO: (String) -> (AssistLinkTests) -> Void = { reason in
            { test in
                test.run(ticks: 10)
                test.serverAnswers("rejected", reason)
            }
        }
        let beforeGO: (String) -> (AssistLinkTests) -> Void = { reason in { $0.serverAnswers("rejected", reason) } }
        let cases: [(String, DriveEnd, (AssistLinkTests) -> Void)] = [
            ("tracking lost", .tracking, trackingLost),
            ("too fast", .tooFast, tooFast),
            ("a re-sent start never finished", .noAnswer, neverFinished),
            ("a re-sent start the link could not take", .noAnswer, { $0.resyncIntoAReset() }),
            ("busy before GO", .serverBusy, beforeGO("busy")),
            ("not ready before GO", .serverBusy, beforeGO("sim_not_ready")),
            ("a validation code before GO", .serverRefused, beforeGO("invalid_rate")),
            ("the watchdog after GO", .linkHiccup, afterGO("pose_watchdog_timeout")),
            ("a late rejection after GO", .serverRefused, afterGO("ik_failed")),
        ]
        for (what, end, cause) in cases {
            bringUp()
            latch()
            cause(self)
            XCTAssertEqual(endings, [.ended(end)], what)
            XCTAssertFalse(
                heard.contains {
                    if case .letGo = $0 { return true }
                    if case .refused = $0 { return true }
                    return false
                }, "\(what): \(heard)")
            assertOver(what)
        }
    }

    /// A refusal of the follow's start because the robot is stopped turns into no ending of its own: the alarm tells
    /// it when the session latches the stop from the state that follows. The link records it as told, so the input
    /// rules add no ending either, and the alarm is the one cue.
    func testARefusalWithNoDriveEndingIsRecordedAnnounced() {
        bringUp()
        latch()
        serverAnswers("rejected", "estop_active")
        XCTAssertEqual(heard, [], "nothing until the stop is known")
        assertOver("refused for a stopped robot")
        transport.server("state", ["estop": true, "gripper": "closed"])
        XCTAssertTrue(model.session.state.emergencyStop)
        XCTAssertEqual(heard, [.emergencyStop(.other, takeDiscarded: false)])
    }

    /// The same answers on a hold someone holds are told as in version 1.0.1, whatever lock is chosen: before GO the
    /// refusal's "Stopped." and then the alarm; after GO the late rejection's let-go and then the alarm.
    func testAStoppedRobotsAnswerToAHeldHoldIsOneZeroOne() {
        let scripts: [(String, Int, [CueKey])] = [
            ("before GO", 0, [.refused(.emergencyStop), .emergencyStop(.other, takeDiscarded: false)]),
            ("after GO", 10, [.holdLive, .letGo(.lateRejection), .emergencyStop(.other, takeDiscarded: false)]),
        ]
        // A hold, the server's refusal for a stopped robot, then its stop state.
        let refusedForAStop: (AssistLinkTests, Int) -> Void = { test, ticks in
            test.model.send(.holdArmStart)
            test.run(ticks: ticks)
            test.serverAnswers("rejected", "estop_active")
            test.transport.server("state", ["estop": true, "gripper": "closed"])
        }
        for (what, ticks, cues) in scripts {
            bringUp(assistOn: false, lock: .off)
            refusedForAStop(self, ticks)
            XCTAssertEqual(heard, cues, "\(what), the aids off")
            let messages = transport.lines, words = speech.spoken
            for lock in LockChoice.allCases {
                bringUp(assistOn: true, lock: lock)
                refusedForAStop(self, ticks)
                XCTAssertEqual(heard, cues, "\(what), lock \(lock)")
                XCTAssertEqual(transport.lines, messages, "\(what), lock \(lock)")
                XCTAssertEqual(speech.spoken, words, "\(what), lock \(lock)")
            }
        }
    }

    /// A slow link ends a follow from the input rules, which name it, once. No ending the link causes is a slow link:
    /// the link's let-gos and every answer the server can give a running hold are named above, and a refusal that names
    /// a slow link comes only from a press the session refused, which a running hold never is.
    func testASlowLinkEndsAFollowAsSlowLinkNeverAsARefusal() {
        bringUp()
        latch()
        model.send(.linkLatency(ms: 500))
        XCTAssertEqual(endings, [], "one slow sample is not a slow link")
        model.send(.linkLatency(ms: 500))
        XCTAssertTrue(model.session.state.commandsBlocked)
        XCTAssertEqual(endings, [.ended(.slowLink)])
        XCTAssertFalse(heard.contains(.refused(.slowLink)))
        assertOver("a slow link")
    }

    /// Version 1.0.1's scripts for a hold someone holds give the same messages, the same cues and the same words with
    /// the aids on, whatever lock is chosen: the link turns nothing into a follow's ending unless the hold is one
    /// nobody holds.
    func testANonLooseHoldIsOneZeroOne() {
        let scripts: [(String, (AssistLinkTests) -> Void)] = [
            (
                "the phone's offset, then the release",
                { test in
                    test.model.send(.holdArmStart)
                    test.position = SIMD3(0.01, 0, -0.02)
                    test.tick()
                    test.model.send(.holdArmEnd)
                    test.position = SIMD3(0.05, 0, 0)
                    test.tick()
                }
            ),
            (
                "the offset from where the hold began",
                { test in
                    test.position = SIMD3(1, 2, 3)
                    test.model.send(.holdArmStart)
                    test.position = SIMD3(1, 2.01, 3)
                    test.tick()
                }
            ),
            (
                "tracking lost",
                { test in
                    test.model.send(.holdArmStart)
                    test.position = nil
                    test.tick()
                }
            ),
            (
                "too fast",
                { test in
                    test.model.send(.holdArmStart)
                    for _ in 0..<10 { test.tick() }
                    test.position = SIMD3(0.2, 0, 0)
                    test.tick()
                }
            ),
            (
                "the server's watchdog",
                { test in
                    test.model.send(.holdArmStart)
                    for _ in 0..<10 { test.tick() }
                    test.serverAnswers("rejected", "pose_watchdog_timeout")
                }
            ),
        ]
        for (what, script) in scripts {
            bringUp(assistOn: false, lock: .off)
            script(self)
            let messages = transport.lines, cues = heard, words = speech.spoken
            for lock in LockChoice.allCases {
                bringUp(assistOn: true, lock: lock)
                script(self)
                XCTAssertEqual(transport.lines, messages, "\(what), lock \(lock)")
                XCTAssertEqual(heard, cues, "\(what), lock \(lock)")
                XCTAssertEqual(speech.spoken, words, "\(what), lock \(lock)")
                XCTAssertFalse(model.link.holdIsLoose, "\(what), lock \(lock)")
            }
        }
    }

    /// The arm reported at the origin, then the hand 20 cm to the right in a third of a second: more than one server
    /// hold may ask for, so the link catches up and re-sends the start after 1.5 s.
    private func sweepRight() {
        transport.server("state", ["estop": false, "ee_pos": [0.0, 0.0, 0.1]])
        for step in 1...10 {
            position = SIMD3(0.02 * Float(step), 0, 0)
            tick()
        }
    }

    /// The link re-sends the start, and a scene reset asked of it meanwhile makes the server unable to take it: the
    /// link cannot continue the hold.
    private func resyncIntoAReset() {
        sweepRight()
        run(ticks: 50)
        XCTAssertEqual(transport.types.last { $0 != "test" }, "pose_stop", "the re-sent start began")
        XCTAssertTrue(model.link.resetScene())
        let start = lastSeq(of: "pose_start")
        transport.server("ack", seq: start, ["seq": start, "status": "ok", "reason": "pose_stopped"])
        transport.server("state", ["estop": false, "ee_pos": [-0.03, 0.0, 0.1]])
    }
}
