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
/// version 1.0.1. The link also says where the arm was last measured, how long ago, and when it pauses a hold. A move
/// to a point tapped on the guide streams the input rules' offsets through the lead cap and re-sends its start as a
/// pad hold does, and the limits it meets are told by its ending alone: neither a side, the server's clamp, "Blocked."
/// nor "Can't go lower." is heard while it goes, and the guide shows no side for it, where a latched follow, which the
/// phone steers, is told its side, the server's clamp, "Blocked." and "Can't go lower.".
final class AssistLinkTests: XCTestCase {
    private var transport: LooseLinkTransport!
    /// The listening connection's socket, once the link opened it.
    private var observer: LooseLinkTransport?
    private var position: SIMD3<Float>? = .zero
    private var clock = 10_000
    private var model: AppModel!
    private var felt = SpyHaptics()
    private var speech = SpySpeech()
    private var savedLanguage = L10n.language
    private var savedMode: String?
    private var savedTaskAid: Any?
    /// The cue log's length when the follow latched.
    private var mark = 0

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.language
        L10n.language = .en
        savedMode = UserDefaults.standard.string(forKey: AppModel.controlModeKey)
        savedTaskAid = UserDefaults.standard.object(forKey: AppModel.taskAidKey)
    }

    /// Both of the aids' settings are removed, never put back: a launch argument shadows the saved value, so a value
    /// read here and written back could be the argument's, saved for good. The models here are given the aids and
    /// save nothing; this keeps it so if a test ever sets them. The task aid, which draws the guide a tap needs, is put
    /// back as it was.
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppModel.assistKey)
        UserDefaults.standard.removeObject(forKey: AppModel.lockChoiceKey)
        UserDefaults.standard.set(savedMode, forKey: AppModel.controlModeKey)
        UserDefaults.standard.set(savedTaskAid, forKey: AppModel.taskAidKey)
        L10n.language = savedLanguage
        model = nil
        transport = nil
        observer = nil
        super.tearDown()
    }

    /// Standby on the real server in scheme A with the link up, the aids given to the model without saving them, and
    /// nothing felt or heard yet.
    private func bringUp(assistOn: Bool = true, lock: LockChoice = .pressPress) {
        position = .zero
        clock = 10_000
        felt = SpyHaptics()
        speech = SpySpeech()
        observer = nil
        model = AppModel(
            start: .p4, haptics: felt, sounds: SpySounds(), speech: speech,
            pose: { [unowned self] in position.map { TestPose.portrait(at: $0) } },
            liveLink: true,
            makeTransport: { [unowned self] _ in
                let made = LooseLinkTransport()
                transport = made
                return made
            },
            makeObserverTransport: { [unowned self] _ in
                let made = LooseLinkTransport()
                observer = made
                return made
            },
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
            XCTAssertEqual(model.operating.state, .ended(end), "\(what): the screen says why")
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

    /// The link pauses the hold while a start waits behind a finishing hold, while the command is held at the lead cap
    /// and while it re-sends the start: the arm may stand still then for a reason that says nothing about where it can
    /// go.
    func testHoldPausedDuringAResyncAndAHeldBackStart() {
        bringUp(lock: .off)
        XCTAssertFalse(model.link.holdPaused, "no hold")
        // The jaws close and are let go of: the arm's start waits on the wire for the server to finish them.
        model.send(.gripperStart(.closed))
        clock += 20
        model.send(.gripperEnd)
        let jaws = lastSeq(of: "gripper_jog_start")
        model.send(.holdArmStart)
        XCTAssertTrue(model.session.state.armMoving)
        XCTAssertFalse(transport.types.contains("pose_start"), "the start waits")
        XCTAssertTrue(model.link.holdPaused, "a start held back")
        transport.server("ack", seq: jaws, ["seq": jaws, "status": "ok", "reason": "gripper_jog_stopped"])
        XCTAssertEqual(transport.types.last, "pose_start")
        XCTAssertFalse(model.link.holdPaused, "the start went out")

        // The hand runs 20 cm ahead: the command is held at the cap, and after 1.5 s the start is re-sent.
        sweepRight()
        XCTAssertTrue(model.link.holdPaused, "the command held at the lead cap")
        run(ticks: 50)
        XCTAssertEqual(transport.types.last { $0 != "test" }, "pose_stop", "the re-sent start began")
        XCTAssertTrue(model.link.holdPaused, "re-sending the start")
        let start = lastSeq(of: "pose_start")
        transport.server("ack", seq: start, ["seq": start, "status": "ok", "reason": "pose_stopped"])
        XCTAssertTrue(model.link.holdPaused, "the old hold finished, the arm's position not yet known")
        transport.server("state", ["estop": false, "ee_pos": [-0.03, 0.0, 0.1]])
        XCTAssertEqual(transport.types.last, "pose_start", "started again from where the arm got")
        XCTAssertFalse(model.link.holdPaused, "the start went out again")
        tick()
        XCTAssertTrue(model.link.holdPaused, "the hand still more than the cap ahead")
        model.send(.holdArmEnd)
        XCTAssertFalse(model.link.holdPaused, "no hold")
    }

    /// A hand more than the lead cap ahead of the arm has its command held at the cap, so the arm is held short: the
    /// hold counts as paused until the command is within the cap again.
    func testHoldPausedWhileTheCommandIsHeldAtTheLeadCap() {
        bringUp(lock: .off)
        transport.server("state", ["estop": false, "gripper": "closed", "ee_pos": [0.0, 0.0, 0.1]])
        model.send(.holdArmStart)
        for x: Float in [0.02, 0.04, 0.06] {
            position = SIMD3(x, 0, 0)
            tick()
        }
        XCTAssertEqual(transport.types.last, "pose_update")
        XCTAssertFalse(model.link.holdPaused, "6 cm ahead: within the cap")
        for x: Float in [0.08, 0.1] {
            position = SIMD3(x, 0, 0)
            tick()
        }
        XCTAssertTrue(model.link.holdPaused, "10 cm ahead: held at the cap")
        for x: Float in [0.085, 0.07] {
            position = SIMD3(x, 0, 0)
            tick()
        }
        XCTAssertFalse(model.link.holdPaused, "7 cm ahead: within the cap again")
        XCTAssertTrue(model.session.state.armMoving)
    }

    /// The newest position either connection reported, and how old it is: since it arrived, plus half the median
    /// round trip, because the server measured it before sending it. A state with no position leaves it as it was,
    /// and closing the link forgets it.
    func testTheNewestArmIsTheNewestStateWithAPosition() {
        bringUp(lock: .off)
        XCTAssertNil(model.link.newestArmState, "no position reported yet")
        XCTAssertNil(model.link.newestArmAgeMs)
        transport.server("state", ["estop": false, "gripper": "closed", "ee_pos": [0.02, -0.14, 0.16]])
        let arrived = clock
        clock += 50
        XCTAssertEqual(model.link.newestArmState?.endEffector, SIMD3(0.02, -0.14, 0.16))
        XCTAssertEqual(model.link.newestArmAgeMs, 50, "no round trip measured yet")
        transport.server("state", ["estop": false, "gripper": "closed"])
        XCTAssertEqual(model.link.newestArmState?.endEffector, SIMD3(0.02, -0.14, 0.16), "a state with no position")
        XCTAssertEqual(model.link.newestArmAgeMs, 50, "counted from the state that carried it")
        // Round trips of 100, 60 and 80 ms: the median is 80, half of it 40.
        for ms in [100, 60, 80] { answerTheNextProbe(after: ms) }
        XCTAssertEqual(model.link.newestArmAgeMs, clock - arrived + 40)

        observer?.server("welcome", ["session": "run-1"])
        observer?.server("state", ["estop": false, "gripper": "closed", "ee_pos": [0.03, -0.15, 0.12]])
        XCTAssertEqual(model.link.newestArmState?.endEffector, SIMD3(0.03, -0.15, 0.12), "the listening connection's")
        XCTAssertEqual(model.link.newestArmAgeMs, 40)

        model.link.closeQuietly()
        XCTAssertNil(model.link.newestArmState, "a closed link measures nothing")
        XCTAssertNil(model.link.newestArmAgeMs)
    }

    /// A move to a point is a hold on the pad's path. With no tracked pose, where a phone hold is refused, it starts,
    /// marked as one nobody holds, with no refusal of its own. Twenty ticks without tracking neither end it nor send an
    /// offset, since the input rules run no move to give one, and nothing ending is heard. Its end sends the stop and
    /// clears the mark.
    func testAGoingHoldNeedsNoTrackedPose() {
        bringUp(lock: .off)
        position = nil
        model.send(.holdArmStart)
        XCTAssertFalse(model.session.state.armMoving, "a phone hold needs the phone's pose")
        XCTAssertEqual(heard, [.refused(.notTracking)])
        let sent = transport.sent.count
        model.startArmHold(.going)
        XCTAssertTrue(model.session.state.armMoving)
        XCTAssertEqual(transport.types.last, "pose_start", "started with no pose")
        XCTAssertTrue(model.link.holdIsLoose, "nobody holds it")
        XCTAssertEqual(heard, [.refused(.notTracking)], "no refusal of its own")
        run(ticks: 20)
        XCTAssertTrue(model.session.state.armMoving, "lost tracking does not end it")
        XCTAssertTrue(model.link.holdIsLoose)
        XCTAssertFalse(transport.types.dropFirst(sent).contains("pose_update"), "no move of the rules, no offset")
        XCTAssertEqual(endings, [])
        model.send(.holdArmEnd)
        XCTAssertEqual(transport.types.last { $0 != "test" }, "pose_stop")
        XCTAssertFalse(model.link.holdIsLoose)
    }

    /// A move to a point the link cannot start is refused as a pad hold is, with the same words and nothing on the
    /// wire, and the session drops the hold: no link (a link being replaced, which the session still reads as
    /// connected), and a scene reset waiting for its answer.
    func testAGoingStartThatCannotStartTakesThePadsFailurePath() {
        let causes: [(String, Refusal, (AssistLinkTests) -> Void)] = [
            ("no link", .noLink, { $0.model.connect() }),
            ("a scene reset waiting", .notReady, { XCTAssertTrue($0.model.link.resetScene()) }),
        ]
        for (what, refusal, cause) in causes {
            for source in [ArmSource.pad, .going] {
                bringUp(lock: .off)
                cause(self)
                XCTAssertTrue(model.session.state.connected, what)
                let sent = transport.sent.count
                if source == .pad { model.startButtonTranslation() } else { model.startArmHold(source) }
                XCTAssertFalse(model.session.state.armMoving, "\(what), \(source)")
                XCTAssertFalse(model.link.holdIsLoose, "\(what), \(source)")
                XCTAssertEqual(heard, [.refused(refusal)], "\(what), \(source)")
                XCTAssertFalse(transport.types.dropFirst(sent).contains("pose_start"), "\(what), \(source)")
            }
        }
    }

    // MARK: A move to a point tapped on the guide

    /// About where the reference phone draws the guide's view from above; the model is told it as the screen would.
    private static let panel = SurfaceLayout.Rect(x: 118, y: 262, width: 166, height: 166)
    /// Where the move starts and where it is sent, robot base frame, pinch point: both at the travel height, 12 cm
    /// apart, so the command can run more than the lead cap ahead of an arm that does not move.
    private let goStart = SIMD3<Double>(-0.03, -0.18, 0.09)
    private let goTarget = SIMD3<Double>(0.09, -0.18, 0.09)

    /// A state with the gripper link where the profile puts the pinch point at `pinch`.
    private func reportArm(atPinch pinch: SIMD3<Double>) {
        let gripper = pinch - SIMD3<Double>(model.profile.toolOffset)
        transport.server("state", ["estop": false, "gripper": "closed", "ee_pos": [gripper.x, gripper.y, gripper.z]])
    }

    /// Standby with no lock, the arm reported at `start` (`goStart` when nil), the guide drawn and its view from above
    /// reported; a tap over `target` (`goTarget` when nil), and the input rules' next look at the arm, still at the
    /// travel height, which turns the move toward the target. The move runs, nobody holds it, and nothing has been
    /// heard.
    private func tapAMove(from start: SIMD3<Double>? = nil, to target: SIMD3<Double>? = nil, line: UInt = #line) {
        bringUp(lock: .off)
        model.taskAid = true
        model.surfaceChanged(width: 402, height: 874, safeTop: 62, safeBottom: 34)
        reportArm(atPinch: start ?? goStart)
        model.guidePanelChanged(Self.panel)
        guard let panel = model.inputFacts().goPanel else { return XCTFail("no panel reaches the rules", line: line) }
        let point = panel.point(over: target ?? goTarget)
        clock += 50
        model.touch(TouchSample(id: 1, phase: .began, x: point.x, y: point.y, majorRadius: 8), at: Double(clock) / 1000)
        clock += 50
        model.touch(TouchSample(id: 1, phase: .ended, x: point.x, y: point.y, majorRadius: 8), at: Double(clock) / 1000)
        clock += 33
        model.controller.tick()
        guard case .going? = model.controller.arbiter.engagement else {
            return XCTFail("no move: \(String(describing: model.controller.arbiter.engagement))", line: line)
        }
        XCTAssertTrue(model.session.state.armMoving, line: line)
        XCTAssertTrue(model.link.holdIsLoose, line: line)
        XCTAssertEqual(transport.types.last, "pose_start", line: line)
        XCTAssertEqual(heard, [], line: line)
    }

    /// Every offset sent for the newest translation hold, as asked, metres in the link's frame.
    private var offsetsSent: [SIMD3<Double>] {
        transport.sent.filter { $0["type"] as? String == "pose_update" }.map { message in
            let p = (message["payload"] as! [String: Any])["p_rel_m"] as! [Double]
            return SIMD3(p[0], p[1], p[2])
        }
    }

    /// A move streams the input rules' offsets through the lead cap every hold has. While the arm is within the cap
    /// each update is the rules' offset; with the arm not seen to move the command runs ahead at the move's speed, no
    /// update ever asks for more than 8 cm, and the hold counts as paused once one is held at the cap.
    func testAGoingHoldStreamsTheOffsetThroughTheLeadCap() throws {
        tapAMove()
        tick()
        let first = try XCTUnwrap(offsetsSent.last)
        let asked = try XCTUnwrap(model.controller.goOffset())
        // The wire carries tenths of a millimetre on each axis.
        XCTAssertEqual(simd_distance(first, asked), 0, accuracy: 0.0001, "the input rules' offset, as asked")
        XCTAssertGreaterThan(simd_length(first), 0, "on its way")
        let cap = Double(LiveLinkController.maxLeadMeters)
        var capped = false
        for _ in 0..<90 where !capped {
            run(ticks: 1)
            capped = offsetsSent.last.map { simd_length($0) >= cap - 0.0005 } ?? false
        }
        XCTAssertTrue(capped, "the command ran more than the cap ahead")
        XCTAssertTrue(model.link.holdPaused, "a hold held at the cap is paused")
        let farthest = offsetsSent.map(simd_length).max() ?? 0
        XCTAssertLessThanOrEqual(farthest, cap + 0.0005, "never more than the cap")
        XCTAssertTrue(model.session.state.armMoving)
        XCTAssertNotNil(model.controller.loose, "the move goes on")
        XCTAssertEqual(endings, [])
    }

    /// A move whose command runs more than the cap ahead re-sends its start as a pad hold does: the link stops the
    /// server's hold, asks nothing while it waits, starts again from where the server says the arm got to, and asks
    /// for the rest of the rules' offset from there. The move goes on, nobody holding it, and nothing is heard.
    func testAGoingHoldResyncsAsAPadHoldDoes() throws {
        tapAMove()
        for _ in 0..<90 where transport.types.last(where: { $0 != "test" }) != "pose_stop" { run(ticks: 1) }
        XCTAssertEqual(transport.types.last { $0 != "test" }, "pose_stop", "the start is being re-sent")
        XCTAssertTrue(model.link.holdPaused, "re-sending the start")
        let updates = offsetsSent.count
        run(ticks: 5)
        XCTAssertEqual(offsetsSent.count, updates, "nothing is asked while waiting")

        // The old hold finished with the arm 3 cm along the way.
        serverAnswers("ok", "pose_stopped")
        let moved = SIMD3<Double>(0.03, 0, 0)
        reportArm(atPinch: goStart + moved)
        XCTAssertEqual(transport.types.last, "pose_start", "started again from where the arm got")
        tick()
        let sent = try XCTUnwrap(offsetsSent.last)
        let asked = try XCTUnwrap(model.controller.goOffset())
        let rest = asked - OperatorFrame.link(fromBase: moved)
        XCTAssertLessThan(simd_length(rest), Double(LiveLinkController.maxLeadMeters), "within the cap again")
        XCTAssertEqual(simd_distance(sent, rest), 0, accuracy: 0.0001, "the rest of the rules' offset")
        XCTAssertTrue(model.session.state.armMoving)
        XCTAssertNotNil(model.controller.loose, "the move goes on")
        XCTAssertTrue(model.link.holdIsLoose, "nobody holds it")
        XCTAssertEqual(endings, [])
    }

    /// Against a server that keeps the gripper link within 4 cm of where it stood, a tap 5.5 cm to the operator's left,
    /// 2 cm inside the work box's left face: the server takes the hold, holds the arm 1.5 cm short and says it clamped
    /// it, and the move corrects as often as the profile allows and stops short. The operator steered nothing, so the
    /// limit is told once, by the move's ending: GO, then the ending, nothing between, and the guide shows no side.
    func testAMoveCutShortByASmallerServerBoxIsToldByItsEndingAlone() {
        // Left is +X in the robot base.
        let start = SIMD3<Double>(0.032617, -0.18, 0.09)
        tapAMove(from: start, to: start + SIMD3(0.055, 0, 0))
        let gripperStart = start - SIMD3<Double>(model.profile.toolOffset)
        let serverEdge = gripperStart.x + 0.04
        var sideShown = false
        for _ in 0..<300 where model.session.state.armMoving {
            run(ticks: 1)
            let commanded = model.link.commandedArm.map { SIMD3<Double>($0) } ?? gripperStart
            let arm = SIMD3(min(commanded.x, serverEdge), commanded.y, commanded.z)
            let label = commanded.x > serverEdge ? "pose_clamped" : "pose_tracking"
            transport.server(
                "state", ["estop": false, "gripper": "closed", "ik": label, "ee_pos": [arm.x, arm.y, arm.z]])
            sideShown = sideShown || model.link.commandOutside != nil
            model.controller.tick()
        }
        XCTAssertFalse(model.session.state.armMoving, "the move ended")
        XCTAssertEqual(heard, [.holdLive, .drive(.ended(.stoppedShort))], "GO, the ending, nothing between")
        XCTAssertFalse(sideShown, "the guide showed no side")
    }

    /// The arm stands 1 cm past the work box's forward face (a server whose box is larger lets it) and the tap is
    /// inside the box: the move's first commands are past that face, and still no side is told or shown, since the
    /// operator steers nothing. The move goes on.
    func testAMoveThatBeginsPastAFaceTellsNoSide() throws {
        let profile = RobotProfile.so101Simulator
        // Forward is −Y in the robot base.
        let start = SIMD3<Double>(0.027617, Double(profile.workspaceMin.y) - 0.01, 0.09)
        tapAMove(from: start, to: SIMD3(start.x, -0.2, start.z))
        let face = Double(profile.workspaceMin.y - profile.toolOffset.y)
        var past = false
        for _ in 0..<6 {
            run(ticks: 1)
            let commanded = try XCTUnwrap(model.link.commandedArm)
            past = past || Double(commanded.y) < face - WorkAreaCue.slackMeters
            XCTAssertNil(model.link.commandOutside, "no side shown")
            model.controller.tick()
        }
        XCTAssertTrue(past, "the command was past the forward face by more than the rule's slack")
        XCTAssertEqual(heard, [], "no side told")
        XCTAssertTrue(model.session.state.armMoving, "the move goes on")
    }

    /// A follow latched by a press is steered by the phone: past the work box's forward face it is told its side, and
    /// the guide shows it, as a held hold is.
    func testALatchedFollowPastAFaceIsStillToldItsSide() {
        bringUp(lock: .pressPress)
        // 1 cm inside the forward face; forward is −Y in the robot base.
        reportArm(atPinch: SIMD3(0.027617, Double(model.profile.workspaceMin.y) + 0.01, 0.09))
        latch()
        // 3 cm forward (ARKit forward is −z), a centimetre a tick: 2 cm past the face.
        for step in 1...3 {
            position = SIMD3(0, 0, -0.01 * Float(step))
            tick()
        }
        XCTAssertEqual(model.link.commandOutside, .forward, "the guide shows the side")
        XCTAssertEqual(heard, [.commandOutside(.forward)], "told its side")
    }

    /// How far to the operator's left of where the gripper link stood the smaller server box below lets it go: farther
    /// than one server hold may ask for, so a command held at the lead cap is still inside it, and short of the 12 cm
    /// the tests here ask for.
    private static let smallerBoxReach = 0.095

    /// Runs the translation hold against a server whose box is smaller than the profile's: it keeps the gripper link
    /// within `smallerBoxReach` to the operator's left of `gripperStart`, the arm following the command at once up to
    /// there, and it says it clamped whenever the command is past that. Each step: `hand` with the step's number, a
    /// link tick, the server's answers and a state, and the input rules' tick; `steps` steps, or until the hold ends.
    /// The server finishes an old hold `stopAnsweredAfter` steps after the link stopped it to re-send its start.
    /// Returns the label of the first state after the re-sent start; nil when no start was re-sent.
    private func runAgainstASmallerServerBox(
        from gripperStart: SIMD3<Double>, stopAnsweredAfter wait: Int, steps: Int, hand: (Int) -> Void = { _ in }
    ) -> String? {
        let edge = gripperStart.x + Self.smallerBoxReach
        var stopsAnswered = 0
        var waited = 0
        var firstAfterTheResentStart: String?
        for step in 0..<steps where model.session.state.armMoving {
            hand(step)
            run(ticks: 1)
            if transport.types.filter({ $0 == "pose_stop" }).count > stopsAnswered {
                if waited >= wait {
                    serverAnswers("ok", "pose_stopped")
                    stopsAnswered += 1
                    waited = 0
                } else {
                    waited += 1
                }
            }
            let commanded = model.link.commandedArm.map { SIMD3<Double>($0) } ?? gripperStart
            let arm = SIMD3(min(commanded.x, edge), commanded.y, commanded.z)
            let label = commanded.x > edge ? "pose_clamped" : "pose_tracking"
            if firstAfterTheResentStart == nil, transport.types.filter({ $0 == "pose_start" }).count > 1 {
                firstAfterTheResentStart = label
            }
            transport.server(
                "state", ["estop": false, "gripper": "closed", "ik": label, "ee_pos": [arm.x, arm.y, arm.z]])
            model.controller.tick()
        }
        return firstAfterTheResentStart
    }

    /// The hand at 4 cm a second to the operator's left (ARKit −x), `step` ticks after the latch, up to 12 cm.
    private func handLeft(_ step: Int) {
        position = SIMD3(-Float(min(0.12, 0.04 * 0.033 * Double(step + 1))), 0, 0)
    }

    /// A move 12 cm to the left, longer than the lead cap, against a server whose box ends 9.5 cm along: the start is
    /// re-sent part way, and the move corrects and stops short. The operator steered nothing, so the limit is told
    /// once, by the move's ending: GO, then the ending, nothing between. So also when the server finishes the old hold
    /// late and answers the re-sent start clamped at once, before it says it tracks that hold: no END is played for
    /// that clamp, and the arm then stands short of the command for more than a second, which is not told "Blocked.".
    func testAMoveLongerThanTheLeadCapIsToldByItsEndingAloneAgainstASmallerServerBox() {
        let answers: [(String, Int, String)] = [
            ("the stop answered at once", 0, "pose_tracking"),
            ("the stop answered late", 20, "pose_clamped"),
        ]
        for (what, wait, firstAnswer) in answers {
            tapAMove()
            let gripperStart = goStart - SIMD3<Double>(model.profile.toolOffset)
            let answer = runAgainstASmallerServerBox(from: gripperStart, stopAnsweredAfter: wait, steps: 300)
            XCTAssertEqual(transport.types.filter { $0 == "pose_start" }.count, 2, "\(what): the start re-sent once")
            XCTAssertEqual(answer, firstAnswer, "\(what): the server's first answer to the re-sent start")
            XCTAssertFalse(model.session.state.armMoving, "\(what): the move ended")
            XCTAssertEqual(
                heard, [.holdLive, .drive(.ended(.stoppedShort))], "\(what): GO, the ending, nothing between")
        }
    }

    /// A follow latched by a press is steered by the phone. In the same case, the hand 12 cm to the left and the server
    /// answering the re-sent start clamped at once, the arm stands short of the command and the follow is told
    /// "Blocked.", as a held hold is; the follow goes on.
    func testALatchedFollowHeldShortByASmallerServerBoxIsStillToldBlocked() {
        bringUp(lock: .pressPress)
        reportArm(atPinch: goStart)
        latch()
        let gripperStart = goStart - SIMD3<Double>(model.profile.toolOffset)
        let answer = runAgainstASmallerServerBox(
            from: gripperStart, stopAnsweredAfter: 20, steps: 150, hand: handLeft)
        XCTAssertEqual(transport.types.filter { $0 == "pose_start" }.count, 2, "the start re-sent once")
        XCTAssertEqual(answer, "pose_clamped", "the server's first answer to the re-sent start")
        XCTAssertEqual(heard, [.holdLive, .limit(.blocked)])
        XCTAssertEqual(model.controller.arbiter.engagement, .latched(since: 10.1), "the follow goes on")
    }

    /// The same follow and server, the server answering the re-sent start at once: it says it tracks the hold, then
    /// clamps it with the commanded point inside the profile's box, past no face the work-area rule watches. The
    /// follow is steered by the phone, so the server's clamp END is heard, as for a held hold; the follow goes on.
    func testALatchedFollowStillHearsTheClampOfASmallerServerBox() throws {
        bringUp(lock: .pressPress)
        reportArm(atPinch: goStart)
        latch()
        let gripperStart = goStart - SIMD3<Double>(model.profile.toolOffset)
        let answer = runAgainstASmallerServerBox(
            from: gripperStart, stopAnsweredAfter: 0, steps: 150, hand: handLeft)
        XCTAssertEqual(answer, "pose_tracking", "the server's first answer to the re-sent start")
        // The profile's box is kept for the pinch point; the link commands the gripper link.
        let profile = model.profile
        let pinch = try XCTUnwrap(model.link.commandedArm.map { $0 + profile.toolOffset })
        XCTAssertTrue(
            all(pinch .>= profile.workspaceMin) && all(pinch .<= profile.workspaceMax),
            "the commanded point is inside the profile's box")
        XCTAssertEqual(heard, [.holdLive, .limit(.workspace)])
        XCTAssertEqual(model.controller.arbiter.engagement, .latched(since: 10.1), "the follow goes on")
    }

    /// A tap sends the jaws straight down from 6 cm above the travel height, and something stands in the way 3 cm above
    /// it: the server tracks the move, and the arm stands on that thing until the move stops short. The operator
    /// steered nothing, so the limit is told once, by the move's ending: GO, then the ending, nothing between. The
    /// height the arm stood at is kept as after a told "Can't go lower.", so the guide draws its lowest line there.
    func testAMoveDownOntoSomethingAboveTheTravelHeightIsToldByItsEndingAlone() throws {
        let start = SIMD3<Double>(0.027617, -0.18, 0.15)
        tapAMove(from: start, to: SIMD3(start.x, start.y, goTarget.z))
        let gripperStart = start - SIMD3<Double>(model.profile.toolOffset)
        let obstacle = gripperStart.z - 0.03
        for _ in 0..<300 where model.session.state.armMoving {
            run(ticks: 1)
            let commanded = model.link.commandedArm.map { SIMD3<Double>($0) } ?? gripperStart
            let arm = SIMD3(commanded.x, commanded.y, max(commanded.z, obstacle))
            transport.server(
                "state", ["estop": false, "gripper": "closed", "ik": "pose_tracking", "ee_pos": [arm.x, arm.y, arm.z]])
            model.controller.tick()
        }
        XCTAssertFalse(model.session.state.armMoving, "the move ended")
        XCTAssertEqual(heard, [.holdLive, .drive(.ended(.stoppedShort))], "GO, the ending, nothing between")
        let lowest = try XCTUnwrap(model.link.lowestSeen, "the height the arm stood at is kept")
        XCTAssertEqual(lowest, obstacle, accuracy: 0.001, "where the arm stood")
        XCTAssertNotNil(model.operating.guide?.lowestY, "the guide draws its lowest line")
    }

    /// A follow latched by a press is steered by the phone. With the jaws on the table and the hand 6 cm down, the arm
    /// stands on the table, and the follow is told "Can't go lower." once, as a held hold is; the follow goes on.
    func testALatchedFollowPushedIntoTheTableStillHearsItCannotGoLower() {
        bringUp(lock: .pressPress)
        let onTheTable = SIMD3<Double>(0.027617, -0.18, Double(model.profile.tableHeight))
        reportArm(atPinch: onTheTable)
        latch()
        // A centimetre a tick; ARKit up is +y.
        for step in 1...6 {
            position = SIMD3(0, -0.01 * Float(step), 0)
            tick()
        }
        // A state every 198 ms for about 2 s, the arm where it stands.
        let gripper = onTheTable - SIMD3<Double>(model.profile.toolOffset)
        for _ in 0..<10 {
            transport.server(
                "state",
                [
                    "estop": false, "gripper": "closed", "ik": "pose_tracking",
                    "ee_pos": [gripper.x, gripper.y, gripper.z],
                ])
            run(ticks: 6)
        }
        XCTAssertEqual(heard, [.holdLive, .limit(.lowest)], "GO, then the cue, once")
        XCTAssertEqual(model.controller.arbiter.engagement, .latched(since: 10.1), "the follow goes on")
    }

    /// Ticks until the link sends its next probe, then the server answers it `ms` later.
    private func answerTheNextProbe(after ms: Int, line: UInt = #line) {
        let before = transport.sent.count
        for _ in 0..<60 where !transport.types.dropFirst(before).contains("test") { tick() }
        guard let probe = transport.sent.dropFirst(before).last(where: { $0["type"] as? String == "test" }) else {
            return XCTFail("no probe", line: line)
        }
        clock += ms
        transport.server("test", seq: probe["seq"] as! Int)
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
