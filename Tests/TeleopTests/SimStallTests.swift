import TeleopCore
import XCTest
@testable import Teleop

private final class StallTransport: LinkTransport {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    var sent: [[String: Any]] = []
    var closed = false
    /// True: a send stays pending, as a real socket's does for a moment, until `deliver()`; `close()` cancels what is
    /// still pending, as the real socket's cancel does.
    var holdsSends = false
    private var pending: [String] = []

    func open() {}
    func close() {
        closed = true
        pending = []
    }
    func send(_ text: String) {
        guard !holdsSends else {
            pending.append(text)
            return
        }
        sent.append(try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])
    }

    /// The pending sends leave.
    func deliver() {
        let leaving = pending
        pending = []
        for text in leaving { sent.append(try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]) }
    }

    var types: [String] { sent.map { $0["type"] as! String } }

    func server(_ type: String, seq: Int = 0, ts: Int = 0, _ payload: [String: Any] = [:]) {
        let message: [String: Any] = ["v": 1, "type": type, "ts": ts, "seq": seq, "payload": payload]
        onText?(String(data: try! JSONSerialization.data(withJSONObject: message), encoding: .utf8)!)
    }

    func lastSeq(of type: String) -> Int {
        sent.last { $0["type"] as? String == type }!["seq"] as! Int
    }

    /// The final ack for request `seq`.
    func answer(_ seq: Int, _ status: String, _ reason: String) {
        server("ack", seq: seq, ["seq": seq, "status": status, "reason": reason])
    }
}

/// The simulator's main loop stopped while the server's network side kept answering (2026-11-19, 22:05:59): every move
/// was answered busy, the stop could never be released, and the operator was told nothing he could act on. The phone
/// now keeps the stop, sends nothing that could move the arm, says once what happened and what to do, and offers the
/// way back to Connect.
final class SimStallTests: XCTestCase {
    private var transport: StallTransport!
    /// The listening connection, once opened.
    private var observer: StallTransport?
    private var clock = 10_000
    /// The server's monotonic clock, nanoseconds, and the captured time of the state it sends next.
    private var serverNs: UInt64 = 10_127_610_818_058_821
    private var capturedNs: UInt64 = 10_127_610_818_058_821
    private var model: AppModel!
    private var speech = SpySpeech()
    private var savedLanguage = L10n.language

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.language
        L10n.language = .en
    }

    override func tearDown() {
        model = nil
        L10n.language = savedLanguage
        super.tearDown()
    }

    private func makeModel() {
        clock = 10_000
        speech = SpySpeech()
        model = AppModel(
            start: .p4, haptics: SpyHaptics(), sounds: SpySounds(), speech: speech,
            pose: { TestPose.portrait(at: .zero) }, liveLink: true,
            makeTransport: { [unowned self] _ in
                transport = StallTransport()
                return transport
            },
            makeObserverTransport: { [unowned self] _ in
                let made = StallTransport()
                observer = made
                return made
            },
            nowMs: { [unowned self] in clock },
            clientName: "teleop-ios/1.0.0 (7)"
        )
        model.session.state.serverAddress = "100.64.0.1:8765"
        model.session.state.setSmoothing(0)
    }

    /// A `state` 200 ms after the last. `loopRuns`: the loop wrote it just now; otherwise it carries the captured time
    /// of the last state the loop wrote. `newFields`: a server with the loop heartbeat, which says `sim_stalled` itself.
    private func state(
        estop: Bool, loopRuns: Bool, newFields: Bool = false, gapMs: Int = 200, ik: String? = nil, seq: Int = 0
    ) {
        clock += gapMs
        serverNs += UInt64(gapMs) * 1_000_000
        if loopRuns { capturedNs = serverNs - 4_000_000 }
        var payload: [String: Any] = [
            "estop": estop, "gripper": "closed", "ee_pos": [0.02, -0.14, 0.16],
            "timing": [
                "state_id": 1, "captured_monotonic_ns": capturedNs, "sent_monotonic_ns": serverNs,
                "server_clock_id": "run",
            ],
        ]
        if let ik { payload["ik"] = ik }
        if newFields {
            payload["sim_stalled"] = !loopRuns
            payload["loop_age_ms"] = Double(serverNs - capturedNs) / 1_000_000
        }
        transport.server("state", seq: seq, payload)
    }

    /// Connected, idle, the loop running. What was said on connecting is forgotten.
    private func bringUp(newFields: Bool = false) {
        makeModel()
        model.connect()
        transport.server("welcome")
        for _ in 0..<3 { state(estop: false, loopRuns: true, newFields: newFields) }
        speech.spoken = []
    }

    private func count(_ event: CueKey) -> Int { model.cueLog.filter { $0.event == event }.count }
    private var stallAnnouncements: Int { speech.spoken.filter { $0.contains("Simulator not responding") }.count }
    private var backAnnouncements: Int { speech.spoken.filter { $0.contains("The simulator is back") }.count }
    private var alarms: [CueKey] {
        model.cueLog.map(\.event).filter {
            if case .emergencyStop = $0 { return true } else { return false }
        }
    }

    /// The pause's quiet line, nothing new sent, the stop kept if latched, no release and no way back offered yet.
    private func assertPaused(stopped: Bool, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(model.link.simulatorLevel, .paused, context, file: file, line: line)
        XCTAssertEqual(model.operating.state, .simulatorPaused(stopped: stopped), context, file: file, line: line)
        XCTAssertFalse(OperatingWords.offersReconnect(model.operating), context, file: file, line: line)
        XCTAssertFalse(OperatingWords.offersRelease(model.operating), context, file: file, line: line)
        let look = OperatingWords.look(model.operating)
        XCTAssertEqual(
            look.word, L10n.string(stopped ? "state.stopped" : "state.wait"), context, file: file, line: line)
        XCTAssertEqual(look.details, ["Simulator paused. Please wait."], context, file: file, line: line)
        XCTAssertEqual(stallAnnouncements, 0, "\(context): a pause says nothing", file: file, line: line)
    }

    /// The stall's display, the stop kept, the way back offered, the release not.
    private func assertStalledAndKept(_ context: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(model.link.simulatorLevel, .notResponding, context, file: file, line: line)
        XCTAssertTrue(model.session.state.emergencyStop, "\(context): the stop is kept", file: file, line: line)
        XCTAssertEqual(model.operating.state, .simulatorStalled(stopped: true), context, file: file, line: line)
        XCTAssertTrue(OperatingWords.offersReconnect(model.operating), context, file: file, line: line)
        XCTAssertFalse(OperatingWords.offersRelease(model.operating), context, file: file, line: line)
        let look = OperatingWords.look(model.operating)
        XCTAssertEqual(look.word, "Simulator not responding", context, file: file, line: line)
        XCTAssertEqual(look.details, ["The stop stays on. Restart the server."], context, file: file, line: line)
    }

    // MARK: Tonight's sequence, replayed

    /// Tonight's record against a server that sends neither new field: connected to a stopped server whose states
    /// carry a captured time 74 s old that never moves on. The release, the moves, STOP and seven more releases.
    func testTonightOnAnOlderServerTheStopIsKeptAndToldOnce() {
        makeModel()
        model.connect()
        transport.server("welcome")
        serverNs = capturedNs + 73_800_000_000
        state(estop: true, loopRuns: false)
        XCTAssertTrue(model.session.state.emergencyStop, "stopped, on connect")
        XCTAssertFalse(model.link.simulatorStalled, "one old state is not yet a stream")
        state(estop: true, loopRuns: false)
        state(estop: true, loopRuns: false)
        XCTAssertEqual(model.link.simulatorStallTrigger, .frozenTime)
        assertPaused(stopped: true, "after three states whose captured time stood still")

        // 22:07:15: the release; 22:07:18 to 22:08:51: the moves.
        model.send(.releaseStop)
        for _ in 0..<12 {
            state(estop: true, loopRuns: false)
            model.send(.holdArmStart)
            model.send(.holdArmEnd)
            model.send(.gripperStart(.closed))
            model.send(.gripperEnd)
        }
        // 22:08:54: STOP, then seven releases, each followed by the server's stale state.
        model.send(.stop)
        for _ in 0..<7 {
            model.send(.releaseStop)
            state(estop: true, loopRuns: false, gapMs: 3000)
        }

        assertStalledAndKept("after the releases")
        XCTAssertEqual(count(.simulatorStalled), 1, "announced once")
        XCTAssertEqual(stallAnnouncements, 1, "spoken once")
        XCTAssertEqual(alarms, [.emergencyStop(.onConnect, takeDiscarded: false)], "the stop is not announced again")
        XCTAssertEqual(count(.refused(.simulatorStalled)), 8, "each release is felt")
        let sent = Set(transport.types)
        for type in ["estop_reset", "pose_start", "gripper_jog_start", "orient_start", "reset_scene"] {
            XCTAssertFalse(sent.contains(type), "\(type) never went out")
        }
    }

    /// Tonight's busy answers, on a server whose states stopped coming: moves refused busy for over 3 s set the fact,
    /// nothing more goes out, and the operator's own STOP and seven releases change nothing else.
    func testBusyAnswersForThreeSecondsSetItAndNothingMoreGoesOut() {
        bringUp()
        for _ in 0..<8 {
            clock += 500
            model.send(.holdArmStart)
            transport.answer(transport.lastSeq(of: "pose_start"), "rejected", "busy")
        }
        XCTAssertEqual(model.link.simulatorStallTrigger, .busy)
        let startsBefore = transport.types.filter { $0 == "pose_start" }.count
        XCTAssertEqual(startsBefore, 8, "the eighth busy answer, 3.5 s after the first, set it")
        model.send(.holdArmStart)
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertEqual(model.cueLog.last?.event, .refused(.simulatorStalled), "felt, not spoken")
        assertPaused(stopped: false, "busy for 3.5 s")
        model.send(.stop)
        // The server goes on sending its last state, 3 s apart.
        for _ in 0..<7 {
            model.send(.releaseStop)
            state(estop: true, loopRuns: false, gapMs: 3000)
        }
        assertStalledAndKept("after STOP and the releases")
        XCTAssertEqual(transport.types.filter { $0 == "pose_start" }.count, startsBefore, "no new move")
        XCTAssertFalse(transport.types.contains("estop_reset"))
        XCTAssertEqual(alarms, [.emergencyStop(.button, takeDiscarded: false)], "the operator's own STOP is heard")
        XCTAssertEqual(count(.simulatorStalled), 1)
        XCTAssertEqual(stallAnnouncements, 1)
    }

    /// A release the server refuses `estop_not_frozen` while the newest state is already stale: the stop latches again
    /// at once, without the alarm, and the six releases after it never go out.
    func testARefusedReleaseWithAStaleStateKeepsTheStopWithoutTheAlarm() {
        bringUp()
        model.send(.stop)
        state(estop: true, loopRuns: true)
        // The loop stops: the next state is 2.2 s old when sent.
        state(estop: true, loopRuns: false, gapMs: 2200)
        XCTAssertFalse(model.link.simulatorStalled)
        model.send(.releaseStop)
        XCTAssertEqual(transport.types.last, "estop_reset")
        transport.answer(transport.lastSeq(of: "estop_reset"), "rejected", "estop_not_frozen")
        XCTAssertEqual(model.link.simulatorStallTrigger, .releaseRefused)
        assertPaused(stopped: true, "the stop latched again at once")
        state(estop: true, loopRuns: false)
        for _ in 0..<6 {
            model.send(.releaseStop)
            state(estop: true, loopRuns: false, gapMs: 3000)
        }
        assertStalledAndKept("after the refused release")
        XCTAssertEqual(transport.types.filter { $0 == "estop_reset" }.count, 1)
        XCTAssertEqual(alarms, [.emergencyStop(.button, takeDiscarded: false)], "no alarm for an unexplained stop")
        XCTAssertEqual(count(.simulatorStalled), 1)
        XCTAssertEqual(stallAnnouncements, 1)
    }

    /// Reconnect drops the connection and opens Connect; the stop stays latched, to be sent again on the next welcome.
    func testReconnectReturnsToConnectWithTheStopKept() {
        testTonightOnAnOlderServerTheStopIsKeptAndToldOnce()
        let old = transport!
        model.send(.disconnect)
        model.send(.changeServer)
        XCTAssertTrue(old.closed)
        XCTAssertEqual(model.session.route, .s1)
        XCTAssertTrue(model.session.state.emergencyStop)
        XCTAssertFalse(model.link.simulatorStalled, "a new connection judges afresh")
        model.connect()
        transport.server("welcome")
        XCTAssertEqual(transport.types.last, "estop", "the latched stop goes to the restarted server")
    }

    // MARK: A server that says so

    func testAServerThatSaysSoOnConnectIsAnnouncedOnceWithoutTheAlarm() {
        makeModel()
        model.connect()
        transport.server("welcome")
        serverNs = capturedNs + 16_000_000_000
        state(estop: true, loopRuns: false, newFields: true)
        XCTAssertEqual(model.link.simulatorStallTrigger, .serverFlag, "loop_age_ms 16200: not responding at once")
        assertStalledAndKept("on connect")
        XCTAssertEqual(alarms, [], "the announcement tells this stop")
        XCTAssertEqual(count(.simulatorStalled), 1)
    }

    func testAReleaseRefusedSimStalledKeepsTheStop() {
        bringUp(newFields: true)
        model.send(.stop)
        state(estop: true, loopRuns: true, newFields: true)
        model.send(.releaseStop)
        transport.answer(transport.lastSeq(of: "estop_reset"), "rejected", "sim_stalled")
        XCTAssertEqual(model.link.simulatorStallTrigger, .serverRefusal)
        assertPaused(stopped: true, "after the refusal")
        XCTAssertEqual(alarms, [.emergencyStop(.button, takeDiscarded: false)])
    }

    func testAMoveRefusedSimStalledIsNeverToldAsAnOtherRefusal() {
        bringUp(newFields: true)
        model.send(.holdArmStart)
        transport.answer(transport.lastSeq(of: "pose_start"), "rejected", "sim_stalled")
        assertPaused(stopped: false, "after the refusal")
        XCTAssertFalse(model.cueLog.contains { $0.event == .refused(.serverRefused) })
        XCTAssertEqual(count(.serverRefusal(.simulatorStalled, accepted: false)), 1)
    }

    func testFreshStatesClearItAndTheReleaseWorksAgain() {
        bringUp(newFields: true)
        model.send(.stop)
        state(estop: true, loopRuns: false, newFields: true)
        assertPaused(stopped: true, "paused")
        state(estop: true, loopRuns: true, newFields: true)
        state(estop: true, loopRuns: true, newFields: true)
        XCTAssertTrue(model.link.simulatorStalled, "two fresh states are not yet enough")
        state(estop: true, loopRuns: true, newFields: true)
        XCTAssertFalse(model.link.simulatorStalled)
        XCTAssertEqual(model.operating.state, .stopped(cause: .button))
        XCTAssertTrue(OperatingWords.offersRelease(model.operating))
        model.send(.releaseStop)
        XCTAssertEqual(transport.types.last, "estop_reset")
        XCTAssertFalse(model.session.state.emergencyStop)
    }

    // MARK: Signs the app reads itself

    func testAHoldsStopUnansweredForThreeSecondsSetsIt() {
        bringUp()
        model.send(.holdArmStart)
        let start = transport.lastSeq(of: "pose_start")
        model.send(.holdArmEnd)
        XCTAssertEqual(transport.types.last, "pose_stop")
        clock += 2999
        model.link.tick()
        XCTAssertFalse(model.link.simulatorStalled)
        clock += 1
        model.link.tick()
        XCTAssertEqual(model.link.simulatorStallTrigger, .stopUnanswered)
        XCTAssertEqual(model.link.simulatorLevel, .paused)
        XCTAssertNotNil(start)
    }

    func testAnAnsweredStopNeverSetsIt() {
        bringUp()
        model.send(.holdArmStart)
        let start = transport.lastSeq(of: "pose_start")
        model.send(.holdArmEnd)
        transport.answer(start, "ok", "pose_stopped")
        clock += 2999
        model.link.tick()
        transport.server("test", seq: 0)
        clock += 2999
        model.link.tick()
        XCTAssertFalse(model.link.simulatorStalled)
    }

    // MARK: Pauses the loop recovers from

    /// The 4.6 s pause measured while stopped, and a pause during a move's wait: quiet, nothing new sent, and once the
    /// captured time moves again everything is as before, with nothing said.
    func testAFiveSecondPauseThatRecoversSaysNothingAndMovesWorkAgain() {
        bringUp()
        for _ in 0..<25 { state(estop: false, loopRuns: false) }
        assertPaused(stopped: false, "5 s of a captured time that stands still")
        model.send(.holdArmStart)
        XCTAssertFalse(transport.types.contains("pose_start"), "no move while paused")
        XCTAssertEqual(model.cueLog.last?.event, .refused(.simulatorStalled))
        for _ in 0..<3 { state(estop: false, loopRuns: true) }
        XCTAssertEqual(model.link.simulatorLevel, .running)
        // Past the refused press's second on screen.
        for _ in 0..<3 { state(estop: false, loopRuns: true) }
        XCTAssertEqual(model.operating.state, .ready)
        XCTAssertEqual(stallAnnouncements, 0)
        XCTAssertEqual(backAnnouncements, 0, "only a simulator that stopped responding is said to be back")
        XCTAssertEqual(count(.simulatorStalled), 0)
        model.send(.holdArmStart)
        XCTAssertEqual(transport.types.last, "pose_start", "moves go out again")
    }

    /// A scene reset: the server's own `resetting` and one this phone asked for. The loop is silent for seconds and
    /// nothing is shown.
    func testAPauseDuringASceneResetShowsNothing() {
        bringUp()
        for _ in 0..<30 { state(estop: false, loopRuns: false, ik: "resetting") }
        XCTAssertEqual(model.link.simulatorLevel, .running, "6 s of resetting")
        XCTAssertNotEqual(model.operating.state, .simulatorPaused(stopped: false))
        for _ in 0..<3 { state(estop: false, loopRuns: true) }

        model.runReset()
        XCTAssertEqual(transport.types.last, "reset_scene")
        for _ in 0..<40 { state(estop: false, loopRuns: false) }
        XCTAssertEqual(model.link.simulatorLevel, .running, "8 s after the phone's own reset")
        XCTAssertEqual(stallAnnouncements, 0)
    }

    /// A pause that lasts 15 s is not responding: then, once, the message and the way back; when it runs again, once,
    /// that it is back.
    func testAPauseOfFifteenSecondsIsToldOnceAndItsEndToo() {
        bringUp()
        model.send(.stop)
        state(estop: true, loopRuns: true)
        // The states grow older than 2 s after ten of them; the third such pauses it.
        var stale = 0
        while model.link.simulatorLevel == .running, stale < 20 {
            state(estop: true, loopRuns: false)
            stale += 1
        }
        XCTAssertEqual(stale, 12)
        assertPaused(stopped: true, "paused")
        // 8.7 s, the longest pause measured that recovered, is still only paused.
        for _ in 0..<44 { state(estop: true, loopRuns: false) }
        XCTAssertEqual(model.link.simulatorLevel, .paused, "8.8 s paused")
        for _ in 0..<30 { state(estop: true, loopRuns: false) }
        XCTAssertEqual(model.link.simulatorLevel, .paused, "14.8 s paused")
        state(estop: true, loopRuns: false)
        assertStalledAndKept("15 s paused")
        XCTAssertEqual(stallAnnouncements, 1)
        for _ in 0..<10 { state(estop: true, loopRuns: false) }
        XCTAssertEqual(stallAnnouncements, 1, "said once")
        for _ in 0..<3 { state(estop: true, loopRuns: true) }
        XCTAssertEqual(model.link.simulatorLevel, .running)
        XCTAssertEqual(model.operating.state, .stopped(cause: .button), "the stop is still latched")
        XCTAssertEqual(backAnnouncements, 1)
        XCTAssertEqual(count(.simulatorBack), 1)
    }

    /// The server latches the stop itself when its loop stalls with a hold still queued, and answers the hold
    /// `sim_stalled`. The stop is shown as engaged, with no alarm; once the loop runs again the operator hears once why
    /// it stopped and releases it as usual.
    func testAStopTheServerLatchedDuringAPauseIsExplainedOnceAndReleasesNormally() {
        bringUp(newFields: true)
        model.send(.holdArmStart)
        let hold = transport.lastSeq(of: "pose_start")
        state(estop: false, loopRuns: false, newFields: true)
        assertPaused(stopped: false, "the server says its loop stalled")
        transport.answer(hold, "rejected", "sim_stalled")
        state(estop: true, loopRuns: false, newFields: true)
        XCTAssertTrue(model.session.state.emergencyStop, "the server's stop is engaged here too")
        assertPaused(stopped: true, "stopped by the server")
        XCTAssertEqual(alarms, [], "no alarm: the screen says why")
        for _ in 0..<3 { state(estop: true, loopRuns: true, newFields: true) }
        XCTAssertEqual(model.link.simulatorLevel, .running)
        XCTAssertEqual(model.operating.state, .stopped(cause: .other))
        XCTAssertTrue(OperatingWords.offersRelease(model.operating))
        XCTAssertEqual(count(.simulatorAutoStopped), 1)
        XCTAssertEqual(speech.spoken.filter { $0.contains("Simulator paused and stopped") }.count, 1)
        XCTAssertEqual(backAnnouncements, 0, "it never stopped responding")
        model.send(.releaseStop)
        XCTAssertEqual(transport.types.last, "estop_reset")
        XCTAssertFalse(model.session.state.emergencyStop)
        for _ in 0..<3 { state(estop: false, loopRuns: true, newFields: true) }
        XCTAssertEqual(count(.simulatorAutoStopped), 1, "said once")
    }

    /// The operator's own stop, kept through a pause, is not called automatic when the pause ends.
    func testAnOperatorsStopIsNotCalledAutomatic() {
        bringUp(newFields: true)
        model.send(.stop)
        state(estop: true, loopRuns: false, newFields: true)
        model.send(.releaseStop)
        for _ in 0..<3 { state(estop: true, loopRuns: true, newFields: true) }
        XCTAssertEqual(model.link.simulatorLevel, .running)
        XCTAssertEqual(count(.simulatorAutoStopped), 0)
    }

    /// A server that sends neither new field, with a running loop and an idle arm: nothing is ever set, and moves go
    /// out as before.
    func testAnOlderServerWithARunningLoopNeverSetsIt() {
        bringUp()
        for _ in 0..<300 {
            state(estop: false, loopRuns: true)
            model.link.tick()
        }
        XCTAssertFalse(model.link.simulatorStalled)
        XCTAssertEqual(count(.simulatorStalled), 0)
        model.send(.holdArmStart)
        XCTAssertEqual(transport.types.last, "pose_start")
        XCTAssertTrue(model.session.state.armMoving)
    }

    // MARK: Every guard, checked on the wire

    /// The server says its loop stopped: paused, or, with a loop 16 s old, not responding at once.
    private func stall(_ level: SimStallDetector.Level, estop: Bool = false, line: UInt = #line) {
        if level == .notResponding { serverNs += 16_000_000_000 }
        state(estop: estop, loopRuns: false, newFields: true)
        XCTAssertEqual(model.link.simulatorLevel, level, line: line)
    }

    private func sentCount(_ type: String) -> Int { transport.types.filter { $0 == type }.count }

    private static let holds: [(start: TeleopAction, end: TeleopAction, startType: String, stopType: String)] = [
        (.holdArmStart, .holdArmEnd, "pose_start", "pose_stop"),
        (.gripperStart(.closed), .gripperEnd, "gripper_jog_start", "gripper_jog_stop"),
        (.wristStart, .wristEnd, "orient_start", "orient_stop"),
    ]

    /// With the stop off, so no stop rule of the session can be what keeps them back: no start of any kind and no
    /// scene reset goes out while paused or not responding.
    func testEveryStartIsKeptOffTheWireWhileStalledWithTheStopOff() {
        for level in [SimStallDetector.Level.paused, .notResponding] {
            // Each kind on a fresh connection, so none waits behind another's stop.
            for hold in Self.holds {
                bringUp(newFields: true)
                stall(level)
                XCTAssertFalse(model.session.state.emergencyStop, "\(level): the stop is not engaged")
                model.send(hold.start)
                clock += 1000
                model.link.tick()
                XCTAssertEqual(sentCount(hold.startType), 0, "\(level): \(hold.startType) went out")
                model.send(hold.end)
            }
            bringUp(newFields: true)
            stall(level)
            model.runReset()
            XCTAssertEqual(model.cueLog.last?.event, .refused(.simulatorStalled), "\(level): the reset is felt refused")
            clock += 1000
            model.link.tick()
            XCTAssertEqual(sentCount("reset_scene"), 0, "\(level)")
        }
    }

    /// The stop, and the end of a hold whose start went out before the simulator stopped, always go out.
    func testTheStopAndTheEndOfAnActiveHoldGoOutAtEveryLevel() {
        for level in [SimStallDetector.Level.running, .paused, .notResponding] {
            for hold in Self.holds {
                bringUp(newFields: true)
                model.send(hold.start)
                XCTAssertEqual(transport.types.last, hold.startType, "\(level)")
                if level != .running { stall(level) }
                model.send(hold.end)
                XCTAssertEqual(transport.types.last, hold.stopType, "\(level): \(hold.stopType)")
            }
            bringUp(newFields: true)
            if level != .running { stall(level) }
            model.send(.stop)
            XCTAssertEqual(transport.types.last, "estop", "\(level)")
        }
    }

    /// A start already waiting behind a finishing control when the simulator pauses is held to the rule where it would
    /// go on the wire: the final ack or the end of the wait no longer sends it, and the press ends here.
    func testAStartWaitingBehindAStopNeverGoesOutOnceTheSimulatorPauses() {
        for byAck in [true, false] {
            for hold in Self.holds {
                bringUp(newFields: true)
                model.send(hold.start)
                let first = transport.lastSeq(of: hold.startType)
                model.send(hold.end)
                model.send(hold.start)
                XCTAssertEqual(sentCount(hold.startType), 1, "\(hold.startType): waiting behind the stop")
                stall(.paused)
                if byAck {
                    transport.answer(first, "ok", "done")
                } else {
                    clock += TeleopLink.finishWaitMs
                    model.link.tick()
                }
                XCTAssertEqual(sentCount(hold.startType), 1, "\(hold.startType), by ack \(byAck): never went out")
                let s = model.session.state
                XCTAssertFalse(s.armMoving || s.gripperMoving != nil || s.wristMoving, "\(hold.startType): ended")
            }
        }
        // A scene reset this phone asked for keeps every sign back for its allowance, far longer than it can wait to
        // go out, so a waiting reset is held to the rule in the link's own tests.
    }

    /// Paused, then 20 s in the background while the loop ran on: back in the foreground nothing is announced, and the
    /// states that come then clear it.
    func testTimeInTheBackgroundDoesNotCountTowardNotResponding() {
        bringUp(newFields: true)
        stall(.paused)
        model.activeChanged(false)
        clock += 20_000
        model.activeChanged(true)
        model.link.tick()
        XCTAssertEqual(model.link.simulatorLevel, .paused, "only a moment in the foreground so far")
        XCTAssertEqual(stallAnnouncements, 0)
        for _ in 0..<3 { state(estop: false, loopRuns: true, newFields: true) }
        XCTAssertEqual(model.link.simulatorLevel, .running)
        XCTAssertEqual(stallAnnouncements, 0, "it never stopped responding")
    }

    /// Not responding with no stop on: the screen and the announcement say what Reconnect will do, and Reconnect
    /// latches the stop here and sends it before the connection goes; the next welcome sends it again.
    func testReconnectWithoutAStopLeavesTheServerStopped() {
        bringUp(newFields: true)
        stall(.notResponding)
        XCTAssertFalse(model.session.state.emergencyStop)
        XCTAssertTrue(OperatingWords.offersReconnect(model.operating))
        XCTAssertEqual(
            OperatingWords.look(model.operating).details, ["Reconnect turns the stop on. Then restart the server."],
            "no stop is on yet")
        XCTAssertEqual(stallAnnouncements, 1)
        XCTAssertFalse(speech.spoken.contains { $0.contains("Stop stays on") }, "nothing said is untrue")
        let old = transport!
        // What Reconnect does.
        model.stopBeforeReconnect()
        model.send(.disconnect)
        model.send(.changeServer)
        XCTAssertEqual(old.types.last, "estop", "the stop went out before the connection closed")
        XCTAssertTrue(old.closed)
        XCTAssertTrue(model.session.state.emergencyStop, "latched here")
        XCTAssertEqual(alarms, [], "no alarm: the operator pressed Reconnect, not STOP")
        XCTAssertFalse(speech.spoken.contains { $0.contains("Not stopped") })
        XCTAssertEqual(model.session.route, .s1)
        model.connect()
        transport.server("welcome")
        XCTAssertEqual(transport.types.last, "estop", "sent again after the next welcome")
        state(estop: true, loopRuns: true, newFields: true)
        XCTAssertEqual(model.operating.state, .stopped(cause: nil), "no cause is named that did not happen")
        XCTAssertFalse(speech.spoken.contains { $0.contains("You pressed stop") })
    }

    // MARK: Reconnect waits for the stop to leave

    /// Reconnect's `estop` may still be on its way when the connection would close, and closing cancels it: a server
    /// holding no command of this phone's would then never stop. The connection stays until a state the server wrote
    /// after reading the `estop` says stopped.
    func testReconnectClosesOnlyOnceTheServerConfirmsTheStop() {
        bringUp(newFields: true)
        stall(.notResponding)
        let old = transport!
        old.holdsSends = true
        model.reconnect()
        XCTAssertFalse(old.closed, "not closed while the estop may still be pending")
        XCTAssertNotEqual(model.session.route, .s1, "Connect opens once the wait ends")
        XCTAssertTrue(model.session.state.emergencyStop, "latched here at once")
        model.reconnect()
        XCTAssertFalse(old.closed, "a second tap does not cut the wait short")
        old.deliver()
        old.holdsSends = false
        XCTAssertEqual(old.types.filter { $0 == "estop" }.count, 1, "the estop left, once")
        clock += 300
        model.link.tick()
        XCTAssertFalse(old.closed, "the server has not confirmed it yet, and the second is not over")
        state(estop: true, loopRuns: false, newFields: true, seq: old.lastSeq(of: "estop"))
        model.link.tick()
        XCTAssertTrue(old.closed)
        XCTAssertEqual(model.session.route, .s1)
        XCTAssertTrue(model.session.state.emergencyStop)
        XCTAssertEqual(model.practiceBlockedReason, "settings.practice_blocked", "the server confirmed it")
        XCTAssertEqual(alarms, [])
    }

    /// No confirmation within a second: the connection closes all the same, so the operator is never held, and the stop
    /// stays latched here. Nothing shown says the server stopped: Connect says the stop goes out again on connecting,
    /// and the next welcome sends it.
    func testAnUnconfirmedReconnectStopClosesAfterASecondAndSaysOnlyWhatIsTrue() {
        bringUp(newFields: true)
        stall(.notResponding)
        let old = transport!
        old.holdsSends = true
        model.reconnect()
        clock += 999
        model.link.tick()
        XCTAssertFalse(old.closed)
        clock += 1
        model.link.tick()
        XCTAssertTrue(old.closed, "never longer than a second")
        XCTAssertEqual(model.session.route, .s1)
        XCTAssertTrue(model.session.state.emergencyStop, "the stop is never released here")
        XCTAssertEqual(model.practiceBlockedReason, "settings.practice_blocked_unconfirmed")
        XCTAssertEqual(
            L10n.string("settings.practice_blocked_unconfirmed"),
            "Not while the stop is on. The server has not confirmed it; it is sent again on connecting.")
        XCTAssertEqual(alarms, [], "no alarm: the operator pressed Reconnect, not STOP")
        XCTAssertFalse(speech.spoken.contains { $0.contains("Stop stays on") })
        model.connect()
        transport.server("welcome")
        XCTAssertEqual(transport.types.last, "estop", "sent again after the next welcome")
        XCTAssertEqual(model.practiceBlockedReason, "settings.practice_blocked_unconfirmed", "sent, not confirmed")
        state(estop: true, loopRuns: true, newFields: true, seq: transport.lastSeq(of: "estop"))
        XCTAssertEqual(model.practiceBlockedReason, "settings.practice_blocked", "confirmed by the server")
        XCTAssertTrue(model.session.state.emergencyStop)
    }

    /// Reconnect's stop the server never confirmed is owed, as a STOP pressed with no link is: Back from Connect does
    /// not show it as STOPPED and offers no Release, a release sent all the same is refused here and nothing clears the
    /// stop offline, and the next welcome sends the stop again.
    func testAnUnconfirmedReconnectStopCannotBeReleasedOfflineAndGoesOutAgainAfterTheWelcome() {
        bringUp(newFields: true)
        stall(.notResponding)
        let old = transport!
        old.holdsSends = true
        model.reconnect()
        clock += 1000
        model.link.tick()
        XCTAssertTrue(old.closed, "the wait passed unconfirmed")
        XCTAssertEqual(model.session.route, .s1)
        model.send(.s1Back)
        XCTAssertEqual(model.session.route, .p5)
        XCTAssertEqual(model.operating.state, .notConnected(reason: nil), "the robot is not said to be stopped")
        XCTAssertFalse(OperatingWords.offersRelease(model.operating), "no Release while the stop is owed")
        XCTAssertNotEqual(OperatingWords.look(model.operating).word, L10n.string("state.stopped"))
        XCTAssertEqual(model.practiceBlockedReason, "settings.practice_blocked_unconfirmed")
        model.send(.releaseStop)
        XCTAssertTrue(model.session.state.emergencyStop, "the stop is never released here")
        XCTAssertEqual(count(.refused(.noLink)), 1, "the release is refused, and the operator hears why")
        XCTAssertFalse(old.types.contains("estop_reset"))
        model.connect()
        transport.server("welcome")
        XCTAssertEqual(transport.types.last, "estop", "sent again after the next welcome")
        XCTAssertFalse(transport.types.contains("estop_reset"))
        XCTAssertEqual(alarms, [], "no alarm: the operator pressed Reconnect, not STOP")
        state(estop: true, loopRuns: true, newFields: true, seq: transport.lastSeq(of: "estop"))
        XCTAssertEqual(model.operating.state, .stopped(cause: nil), "stopped, confirmed, and no cause is named")
        XCTAssertTrue(OperatingWords.offersRelease(model.operating))
        XCTAssertEqual(model.practiceBlockedReason, "settings.practice_blocked")
    }

    // MARK: Reconnect's stop is recorded as a pressed STOP is

    /// Every connection this test has opened, oldest first, so nothing sent on any of them is missed.
    private var opened: [StallTransport] = []

    /// Connected, idle, not stopped, the simulator not responding, and Reconnect pressed with the `estop` still on its
    /// way: the wait for the server's confirmation has begun. Returns the connection Reconnect sent it on.
    private func reconnectWaiting() -> StallTransport {
        bringUp(newFields: true)
        stall(.notResponding)
        XCTAssertFalse(model.session.state.emergencyStop)
        let old = transport!
        opened = [old]
        old.holdsSends = true
        model.reconnect()
        XCTAssertTrue(model.link.waitingToCloseAfterStop, "the wait has begun")
        XCTAssertTrue(model.session.state.emergencyStop, "latched here at once")
        return old
    }

    /// From wherever a close left the operator, back to the operating screen.
    private func backToOperating(_ context: String, line: UInt = #line) {
        if model.session.route == .s6 { model.send(.settingsDone) }
        if model.session.route == .s1 { model.send(.s1Back) }
        XCTAssertTrue(OperatingController.operatingRoutes.contains(model.session.route), context, line: line)
    }

    /// The stop is unconfirmed and the connection it went out on is gone: nothing offers a release, a release sent
    /// all the same is refused and clears nothing, and no `estop_reset` went out anywhere.
    private func assertNoReleaseWhileUnconfirmed(_ context: String, line: UInt = #line) {
        XCTAssertFalse(OperatingWords.offersRelease(model.operating), "\(context): no Release offered", line: line)
        XCTAssertNotEqual(
            OperatingWords.look(model.operating).word, L10n.string("state.stopped"),
            "\(context): not said to be stopped", line: line)
        XCTAssertEqual(model.practiceBlockedReason, "settings.practice_blocked_unconfirmed", context, line: line)
        model.send(.releaseStop)
        XCTAssertTrue(model.session.state.emergencyStop, "\(context): never released here", line: line)
        XCTAssertFalse(
            opened.contains { $0.types.contains("estop_reset") }, "\(context): no estop_reset", line: line)
    }

    /// After the next welcome the stop goes out again; once a state the server wrote after reading it says stopped and
    /// the simulator runs, the stop shows with its Release, and the Release sends `estop_reset`.
    private func assertSentAgainAndReleasable(_ context: String, line: UInt = #line) {
        if !model.link.isOpen || transport === opened.first { model.connect() }
        let fresh = transport!
        if !opened.contains(where: { $0 === fresh }) { opened.append(fresh) }
        let estopsBefore = fresh.types.filter { $0 == "estop" }.count
        fresh.server("welcome")
        XCTAssertEqual(
            fresh.types.filter { $0 == "estop" }.count, estopsBefore + 1, "\(context): sent again after the welcome",
            line: line)
        XCTAssertEqual(
            model.practiceBlockedReason, "settings.practice_blocked_unconfirmed", "\(context): sent, not confirmed",
            line: line)
        for _ in 0..<3 {
            state(estop: true, loopRuns: true, newFields: true, seq: fresh.lastSeq(of: "estop"))
        }
        XCTAssertEqual(model.link.simulatorLevel, .running, context, line: line)
        XCTAssertEqual(model.operating.state, .stopped(cause: nil), context, line: line)
        XCTAssertEqual(model.practiceBlockedReason, "settings.practice_blocked", context, line: line)
        XCTAssertTrue(OperatingWords.offersRelease(model.operating), "\(context): Release once confirmed", line: line)
        model.send(.releaseStop)
        XCTAssertFalse(model.session.state.emergencyStop, context, line: line)
        XCTAssertEqual(fresh.types.last, "estop_reset", context, line: line)
        XCTAssertEqual(alarms, [], "\(context): no alarm: the operator pressed Reconnect, not STOP", line: line)
        XCTAssertFalse(speech.spoken.contains { $0.contains("Not stopped") }, context, line: line)
    }

    /// The fourth review's sequence: Reconnect, then Settings and Disconnect inside the wait, back to the operating
    /// screen, Release, and a new connection.
    func testDisconnectFromSettingsDuringReconnectsWaitLeavesTheStopOwed() {
        let old = reconnectWaiting()
        model.send(.openSettings)
        XCTAssertEqual(model.session.route, .s6)
        model.send(.disconnect)
        model.send(.changeServer)
        XCTAssertTrue(old.closed)
        XCTAssertFalse(model.link.waitingToCloseAfterStop)
        backToOperating("after Disconnect")
        assertNoReleaseWhileUnconfirmed("after Disconnect")
        assertSentAgainAndReleasable("after Disconnect")
    }

    /// Every way the connection can close before the server confirms Reconnect's stop ends the same way.
    func testEveryEarlyCloseDuringReconnectsWaitLeavesTheStopOwed() {
        let closes: [(name: String, close: (SimStallTests, StallTransport) -> Void)] = [
            (
                "Settings Disconnect",
                { t, _ in
                    t.model.send(.openSettings)
                    t.model.send(.disconnect)
                    t.model.send(.changeServer)
                }
            ),
            ("Disconnect", { t, _ in t.model.send(.disconnect) }),
            ("the socket closed", { _, old in old.onClose?() }),
            (
                "the one-second bound",
                { t, _ in
                    t.clock += LiveLinkController.reconnectStopWaitMs
                    t.model.link.tick()
                }
            ),
        ]
        for (name, close) in closes {
            let old = reconnectWaiting()
            close(self, old)
            XCTAssertTrue(old.closed, "\(name): closed")
            XCTAssertFalse(model.link.waitingToCloseAfterStop, "\(name): the wait is over")
            backToOperating(name)
            assertNoReleaseWhileUnconfirmed(name)
            assertSentAgainAndReleasable(name)
        }
    }

    /// Settings' Connect inside the wait replaces the connection: Reconnect's stop is treated as a pressed STOP is then
    /// (`LiveLinkTests.testAStopNotYetConfirmedGoesOutFirstOnAConnectionThatReplacesTheLink`). It stays latched, goes out
    /// first on the new connection without any alarm, and is released only once that server has confirmed it.
    func testConnectFromSettingsDuringReconnectsWaitSendsTheStopFirstOnTheNewConnection() {
        let old = reconnectWaiting()
        model.send(.openSettings)
        model.connect()
        XCTAssertTrue(old.closed)
        XCTAssertFalse(model.link.waitingToCloseAfterStop, "the wait is over")
        XCTAssertTrue(model.session.state.emergencyStop)
        let fresh = transport!
        XCTAssertFalse(fresh === old)
        opened.append(fresh)
        fresh.server("welcome")
        XCTAssertEqual(fresh.types, ["hello", "estop"], "the stop goes out first")
        model.send(.settingsDone)
        for _ in 0..<3 { state(estop: true, loopRuns: true, newFields: true, seq: fresh.lastSeq(of: "estop")) }
        XCTAssertEqual(model.operating.state, .stopped(cause: nil))
        XCTAssertTrue(OperatingWords.offersRelease(model.operating))
        model.send(.releaseStop)
        XCTAssertEqual(fresh.types.last, "estop_reset")
        XCTAssertFalse(model.session.state.emergencyStop)
        XCTAssertEqual(alarms, [], "no alarm: the operator pressed Reconnect, not STOP")
    }

    // MARK: Settings while the simulator is paused or not responding

    /// The stopped band in Settings says only what can be done now: a reset is refused while the simulator is paused
    /// or not responding, so it is not offered then.
    func testSettingsStoppedBandOffersOnlyWhatCanBeDone() {
        XCTAssertEqual(SettingsScreen.stoppedBandDetail(.stopped(cause: .button)), "settings.stopped")
        XCTAssertEqual(SettingsScreen.stoppedBandDetail(.simulatorPaused(stopped: true)), "settings.stopped_sim_paused")
        XCTAssertEqual(
            SettingsScreen.stoppedBandDetail(.simulatorStalled(stopped: true)), "settings.stopped_sim_stalled")
        XCTAssertNil(SettingsScreen.stoppedBandDetail(.simulatorPaused(stopped: false)), "no stop to show")
        XCTAssertNil(SettingsScreen.stoppedBandDetail(.simulatorStalled(stopped: false)), "no stop to show")
        XCTAssertEqual(
            L10n.string("settings.stopped_sim_paused"),
            "The robot is stopped. The simulator is paused: wait for it to run again.")
        XCTAssertEqual(
            L10n.string("settings.stopped_sim_stalled"),
            "The robot is stopped. The simulator is not responding: tap Done, then Reconnect, or restart the server.")
        L10n.language = .zhHant
        XCTAssertEqual(L10n.string("settings.stopped_sim_paused"), "機器人已急停。模擬器暫停中，請等它恢復。")
        XCTAssertEqual(
            L10n.string("settings.stopped_sim_stalled"), "機器人已急停。模擬器沒有回應：點「完成」再按「重新連線」，或重新啟動伺服器。")
        L10n.language = .en
        for words in ["settings.stopped_sim_paused", "settings.stopped_sim_stalled"] {
            XCTAssertFalse(L10n.string(words).contains("reset"), "\(words): a reset is refused in this state")
        }

        // In the app: paused, then not responding, with the stop on.
        bringUp(newFields: true)
        model.send(.stop)
        stall(.paused, estop: true)
        XCTAssertEqual(SettingsScreen.stoppedBandDetail(model.operating.state), "settings.stopped_sim_paused")
        model.runReset()
        XCTAssertEqual(model.cueLog.last?.event, .refused(.simulatorStalled), "the reset is refused while paused")
        stall(.notResponding, estop: true)
        XCTAssertEqual(SettingsScreen.stoppedBandDetail(model.operating.state), "settings.stopped_sim_stalled")
        XCTAssertTrue(OperatingWords.offersReconnect(model.operating), "Reconnect is there to tap")
    }

    // MARK: Who stopped it while paused

    /// A state saying `sim_stalled` when the server's stop appears names the cause: the operator hears once, when the
    /// simulator runs again, that it stopped automatically.
    func testAStopOnAStateSayingSimStalledIsCalledAutomatic() {
        bringUp(newFields: true)
        stall(.paused)
        state(estop: true, loopRuns: false, newFields: true)
        assertPaused(stopped: true, "stopped by the server")
        for _ in 0..<3 { state(estop: true, loopRuns: true, newFields: true) }
        XCTAssertEqual(model.link.simulatorLevel, .running)
        XCTAssertEqual(count(.simulatorAutoStopped), 1)
        XCTAssertEqual(alarms, [])
    }

    /// A stop of unknown cause during a pause, for example another client's STOP on a server that does not say
    /// `sim_stalled`, is not called automatic: when the simulator runs again it is told as any server stop is.
    func testAStopOfUnknownCauseDuringAPauseIsNotCalledAutomatic() {
        bringUp()
        for _ in 0..<3 { state(estop: false, loopRuns: false, gapMs: 2500) }
        XCTAssertEqual(model.link.simulatorLevel, .paused)
        state(estop: true, loopRuns: false)
        XCTAssertTrue(model.session.state.emergencyStop)
        XCTAssertEqual(alarms, [], "kept quietly while paused")
        for _ in 0..<3 { state(estop: true, loopRuns: true) }
        XCTAssertEqual(model.link.simulatorLevel, .running)
        XCTAssertEqual(count(.simulatorAutoStopped), 0)
        XCTAssertFalse(speech.spoken.contains { $0.contains("Simulator paused and stopped") })
        XCTAssertEqual(alarms, [.emergencyStop(.other, takeDiscarded: false)], "the words of any server stop, once")
        XCTAssertEqual(model.operating.state, .stopped(cause: .other))
    }

    // MARK: Heard in the background

    /// A state can still arrive while the app is in the background. However old the loop it reports, it raises
    /// nothing; after the return the states that come then decide.
    func testAStateHeardInTheBackgroundRaisesNothing() {
        bringUp(newFields: true)
        stall(.paused)
        model.activeChanged(false)
        state(estop: false, loopRuns: false, newFields: true, gapMs: 15_000)
        XCTAssertEqual(model.link.simulatorLevel, .paused, "only a moment was spent waiting in the foreground")
        XCTAssertEqual(stallAnnouncements, 0)
        model.activeChanged(true)
        model.link.tick()
        XCTAssertEqual(model.link.simulatorLevel, .paused)
        for _ in 0..<3 { state(estop: false, loopRuns: true, newFields: true) }
        XCTAssertEqual(model.link.simulatorLevel, .running)
        XCTAssertEqual(stallAnnouncements, 0, "it was never said to stop responding")
    }

    // MARK: Late states without timing

    /// A server that says `sim_stalled` but sends no timing, heard on both connections: a state the other connection
    /// already overtook, by its envelope time, is passed over before the stall decision reads it.
    func testALateStateWithoutTimingFromTheOtherConnectionSaysNothing() throws {
        makeModel()
        model.connect()
        transport.server("welcome")
        let control = transport!
        func plain(_ connection: StallTransport, ts: Int, stalled: Bool, loopAgeMs: Double) {
            clock += 50
            connection.server(
                "state", ts: ts,
                [
                    "estop": false, "gripper": "closed", "ee_pos": [0.02, -0.14, 0.16], "sim_stalled": stalled,
                    "loop_age_ms": loopAgeMs,
                ])
        }
        plain(control, ts: 500, stalled: false, loopAgeMs: 10)
        let listening = try XCTUnwrap(observer, "opened at the welcome")
        listening.server("welcome")
        for ts in [1000, 1200, 1400] { plain(listening, ts: ts, stalled: false, loopAgeMs: 10) }
        XCTAssertEqual(model.link.simulatorLevel, .running)
        // Late, on the control connection: written before the newest seen, and saying the loop stopped long ago.
        plain(control, ts: 900, stalled: true, loopAgeMs: 16_000)
        XCTAssertEqual(model.link.simulatorLevel, .running, "an overtaken state says nothing new")
        plain(listening, ts: 1600, stalled: false, loopAgeMs: 10)
        plain(control, ts: 1100, stalled: true, loopAgeMs: 1000)
        XCTAssertEqual(model.link.simulatorLevel, .running)
        XCTAssertEqual(stallAnnouncements, 0)
        model.send(.holdArmStart)
        XCTAssertEqual(control.types.last, "pose_start", "starts are not blocked")
        model.send(.holdArmEnd)
        // A state newer than every one seen still counts.
        plain(control, ts: 1800, stalled: true, loopAgeMs: 16_000)
        XCTAssertEqual(model.link.simulatorLevel, .notResponding)
    }
}
