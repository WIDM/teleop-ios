import Foundation
import simd
import TeleopCore
import TeleopServerHost
import TeleopServerModel
import XCTest
@testable import Teleop

/// The network path between the phone and the server. While it stalls it holds back every message in both
/// directions, on both of the app's connections; when it comes back it delivers them all at once, in the order they
/// were sent, as an ordinary wireless network was measured doing for up to 1.8 s at a time.
final class StallingPath {
    private(set) var stalled = false
    private var held: [() -> Void] = []
    /// When each connection last handed the app a message, by the order the connections were opened.
    private(set) var lastDelivered: [Int: Date] = [:]
    /// The type of every message the app sent on each connection, in order, held back or not.
    private(set) var sent: [Int: [String]] = [:]
    /// How many connections the app has opened; the next one gets the next number.
    private(set) var opened = 0

    func stall() { stalled = true }

    /// The path comes back: everything held back goes through, in order.
    func resume() {
        stalled = false
        let due = held
        held = []
        for deliver in due { deliver() }
    }

    func transport(_ url: URL) -> LinkTransport {
        opened += 1
        return PathTransport(url: url, path: self, index: opened)
    }

    fileprivate func pass(_ deliver: @escaping () -> Void) {
        if stalled { held.append(deliver) } else { deliver() }
    }

    fileprivate func delivered(on index: Int) { lastDelivered[index] = Date() }

    fileprivate func sending(_ text: String, on index: Int) {
        let message = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        sent[index, default: []].append(message?["type"] as? String ?? "?")
    }
}

/// One of the app's sockets through a `StallingPath`: a real WebSocket to the local server underneath.
private final class PathTransport: LinkTransport {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    private let socket: WebSocketTransport
    private let path: StallingPath
    private let index: Int

    init(url: URL, path: StallingPath, index: Int) {
        socket = WebSocketTransport(url: url)
        self.path = path
        self.index = index
        socket.onText = { [weak self] text in
            self?.path.pass { [weak self] in
                guard let self else { return }
                self.path.delivered(on: index)
                self.onText?(text)
            }
        }
        socket.onClose = { [weak self] in self?.path.pass { self?.onClose?() } }
    }

    func open() { socket.open() }
    func send(_ text: String) {
        path.sending(text, on: index)
        path.pass { [weak self] in self?.socket.send(text) }
    }
    func close() { socket.close() }
}

/// A stall of the network path, against the server model on a local socket with its real 750 ms watchdog. A stall
/// shorter than the link's limit costs the operator the hold the server's watchdog ends ("Link hiccup."), never the
/// session; a longer one is a lost link at 3 s. STOP pressed during a short stall reaches the server when the path
/// comes back. A STOP the server has not confirmed when the link is lost is owed: the operator is told it reached no
/// robot, and it goes out first after the next welcome. Whatever latched the stop, a welcome sends `estop` first.
final class LinkStallTests: XCTestCase {
    private var server: LocalTeleopServer!
    private var path: StallingPath!
    private var hand: ScriptedOperator!
    private var model: AppModel { hand.model }
    /// The operating states shown, in order, each once in a row.
    private var shown: [OperatingState] = []
    /// The same, by name only, for the run's printed line.
    private var shownNames: String {
        shown.map { String(String(describing: $0).prefix { $0 != "(" }) }.reduce(into: [String]()) {
            if $0.last != $1 { $0.append($1) }
        }.joined(separator: ", ")
    }

    override func tearDown() {
        hand?.watch = nil
        hand?.finish()
        hand = nil
        server?.stop()
        server = nil
        path = nil
    }

    private func start(_ mode: ControlMode) throws {
        server = LocalTeleopServer(config: .s4Simulator(stepsPerSecond: 60))
        try server.start()
        path = StallingPath()
        hand = ScriptedOperator(
            address: server.address, mode: mode, smoothing: 0, pace: 0.3,
            makeTransport: { [unowned self] in
                path.transport($0)
            })
        XCTAssertTrue(hand.connect(within: 4), "could not connect to the local server")
        // The 3 s with nothing on either connection counts only with the listening connection up.
        XCTAssertTrue(hand.wait(4, until: { model.link.observerUp }), "the listening connection did not come up")
        hand.pump(1)
        shown = []
        hand.watch = { [unowned self] in
            if shown.last != model.operating.state { shown.append(model.operating.state) }
        }
    }

    private var serverStopped: Bool { server.inspect { $0.state["estop"] } == true }

    /// The cues played from `index` on.
    private func cues(from index: Int) -> [CueLogEntry] { Array(model.cueLog.dropFirst(index)) }

    private func heldLive(_ count: Int) -> Bool { model.cueLog.filter { $0.event == .holdLive }.count >= count }

    /// What every short stall must give once the path is back: the link up, the hold ended by the server's watchdog
    /// with LETGO and "Link hiccup.", no refusal and no lost link, no emergency stop. The screen may show Slow link for
    /// a moment: the probes sent during the stall came back that late.
    private func checkTheHoldEndedAndTheLinkStayed(
        since index: Int, reason: String, _ what: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(model.session.state.connected, "\(what): the link was lost", file: file, line: line)
        let after = cues(from: index)
        let ended = after.filter { $0.event == .letGo(.watchdog) }
        XCTAssertEqual(ended.count, 1, "\(what): \(after.map(\.event))", file: file, line: line)
        XCTAssertEqual(ended.first?.haptic, .letGo, "\(what)", file: file, line: line)
        XCTAssertEqual(ended.first?.speech, [.linkHiccup], "\(what)", file: file, line: line)
        XCTAssertEqual(ended.first?.dropped, false, "\(what): and played", file: file, line: line)
        XCTAssertFalse(
            after.contains {
                if case .refused = $0.event { return true }
                if case .linkLost = $0.event { return true }
                return false
            }, "\(what): \(after.map(\.event))", file: file, line: line)
        XCTAssertTrue(
            model.debugLog.contains { $0.contains(reason) }, "\(what): \(model.debugLog.suffix(8))", file: file,
            line: line)
        XCTAssertFalse(serverStopped, "\(what): the watchdog is no emergency stop", file: file, line: line)
        XCTAssertFalse(
            shown.contains(.linkLost) || shown.contains { if case .refused = $0 { return true } else { return false } },
            "\(what): the screen showed \(shown)", file: file, line: line)
    }

    /// The screen shows the hold while it is live (`live`), and no longer once the server's watchdog ended it while the
    /// operator still holds.
    private func checkTheScreen(
        showsTheHold live: Bool, _ showsTheHold: (OperatingState) -> Bool, _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            showsTheHold(model.operating.state), live,
            "\(what): the screen shows \(model.operating.state) for a hold \(live ? "still live" : "the server ended")",
            file: file, line: line)
    }

    private static func moving(_ state: OperatingState) -> Bool {
        if case .moving = state { return true } else { return false }
    }

    private static func closing(_ state: OperatingState) -> Bool {
        if case .closing = state { return true } else { return false }
    }

    private static func turning(_ state: OperatingState) -> Bool {
        if case .turning = state { return true } else { return false }
    }

    /// Holds the path back for `seconds` while the hand goes on doing what it does, and checks that the link stays up
    /// throughout.
    private func stall(for seconds: TimeInterval, _ what: String) {
        path.stall()
        var lostDuringTheStall = false
        _ = hand.wait(
            seconds,
            until: {
                lostDuringTheStall = lostDuringTheStall || !model.session.state.connected
                return false
            })
        path.resume()
        XCTAssertFalse(lostDuringTheStall, "\(what): the link was lost during a \(seconds) s stall")
    }

    // MARK: Short stalls end the hold, not the session

    func testAStallOf1point8sDuringAnArmHoldEndsTheHoldNotTheLink() throws {
        try start(.screenTurns)
        hand.press(.upper)
        hand.move(to: SIMD3(0, 0, -0.01), in: 0.5)
        XCTAssertTrue(hand.wait(1, until: { heldLive(1) }), "the hold did not go live")
        let index = model.cueLog.count
        checkTheScreen(showsTheHold: true, Self.moving, "arm")
        shown = [model.operating.state]
        stall(for: 1.8, "arm")
        XCTAssertTrue(hand.wait(1, until: { !model.session.state.armMoving }), "the hold did not end")
        // What the screen shows next, while the operator still holds.
        _ = hand.wait(0.5, until: { false })
        checkTheScreen(showsTheHold: false, Self.moving, "arm")
        hand.release(.upper)
        checkTheHoldEndedAndTheLinkStayed(since: index, reason: "hold ended by server: pose_watchdog_timeout", "arm")
        print("STALL arm: the screen showed \(shownNames)")

        // The next hold works: the operator presses again and the arm follows.
        hand.position = .zero
        hand.pump(1)
        let armBefore = server.inspect { $0.world.arm }
        hand.press(.upper)
        XCTAssertTrue(model.session.state.armMoving, "the next press was refused: \(model.cueLog.suffix(2))")
        hand.move(to: SIMD3(0, 0, -0.02), in: 0.5)
        hand.pump(2)
        hand.release(.upper)
        XCTAssertTrue(heldLive(2), "the next hold did not go live")
        let moved = { self.server.inspect { $0.world.arm.y } - armBefore.y }
        // Forward is the robot's −Y.
        XCTAssertTrue(hand.wait(3, until: { abs(moved() + 0.02) <= 0.004 }), "the arm moved \(moved()) m along Y")
    }

    /// The jaws close at 60 degrees a second here: open them first, so a close is still under way when the path stalls.
    func testAStallOf1point8sDuringAGripperHoldEndsTheHoldNotTheLink() throws {
        try start(.buttons)
        hand.gripper(.open, seconds: 5)
        let jawOpen = server.inspect { $0.world.jaw }
        let live = model.cueLog.filter { $0.event == .holdLive }.count
        model.buttonDown(.close)
        XCTAssertTrue(hand.wait(1, until: { heldLive(live + 1) }), "the hold did not go live")
        let index = model.cueLog.count
        checkTheScreen(showsTheHold: true, Self.closing, "gripper")
        shown = [model.operating.state]
        stall(for: 1.8, "gripper")
        XCTAssertTrue(hand.wait(1, until: { model.session.state.gripperMoving == nil }), "the hold did not end")
        // What the screen shows next, while the operator still holds.
        _ = hand.wait(0.5, until: { false })
        checkTheScreen(showsTheHold: false, Self.closing, "gripper")
        model.buttonUp(.close)
        checkTheHoldEndedAndTheLinkStayed(
            since: index, reason: "gripper hold ended by server: gripper_jog_watchdog_timeout", "gripper")
        print("STALL gripper: the screen showed \(shownNames)")
        let jawAfterTheStall = server.inspect { $0.world.jaw }
        XCTAssertLessThan(jawAfterTheStall, jawOpen - 10, "the jaws closed until the watchdog ended the hold")
        XCTAssertGreaterThan(jawAfterTheStall, 10, "and no further")

        // The next hold works.
        hand.pump(1)
        model.buttonDown(.close)
        XCTAssertEqual(model.session.state.gripperMoving, .closed, "the next press was refused")
        hand.pump(2)
        model.buttonUp(.close)
        XCTAssertTrue(heldLive(live + 2), "the next hold did not go live")
        XCTAssertTrue(
            hand.wait(2, until: { self.server.inspect { $0.world.jaw } < jawAfterTheStall - 3 }),
            "the jaws did not close further")
    }

    func testAStallOf1point8sDuringAWristHoldEndsTheHoldNotTheLink() throws {
        try start(.screenTurns)
        let roll0 = server.inspect { $0.world.wristRoll }
        let point = hand.surfaceCentre
        let touch = hand.touchDown(x: point.x, y: point.y)
        _ = hand.wait(0.15, until: { false })
        hand.turnPhone(.turn, to: 10, in: 0.25)
        XCTAssertTrue(hand.wait(1, until: { heldLive(1) }), "the hold did not go live")
        hand.pump(1)
        let index = model.cueLog.count
        checkTheScreen(showsTheHold: true, Self.turning, "wrist")
        shown = [model.operating.state]
        stall(for: 1.8, "wrist")
        XCTAssertTrue(hand.wait(1, until: { !model.session.state.wristMoving }), "the hold did not end")
        // What the screen shows next, while the operator still holds.
        _ = hand.wait(0.5, until: { false })
        checkTheScreen(showsTheHold: false, Self.turning, "wrist")
        hand.touchUp(touch, x: point.x, y: point.y)
        checkTheHoldEndedAndTheLinkStayed(
            since: index, reason: "wrist hold ended by server: orient_watchdog_timeout", "wrist")
        print("STALL wrist: the screen showed \(shownNames)")

        // The next hold works: the wrist turns back.
        hand.rotation = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1))
        hand.pump(1)
        let rollAfterTheStall = server.inspect { $0.world.wristRoll }
        XCTAssertGreaterThan(rollAfterTheStall, roll0 + 5, "the wrist turned until the watchdog ended the hold")
        hand.wrist(.turn, by: -10, hold: 3)
        XCTAssertTrue(heldLive(2), "the next hold did not go live")
        XCTAssertLessThan(server.inspect { $0.world.wristRoll }, rollAfterTheStall - 5, "the wrist did not turn back")
        XCTAssertTrue(model.session.state.connected)
    }

    // MARK: A longer stall is a lost link

    /// Nothing on either connection for 3 s is a lost link: not sooner, and not much later.
    func testAStallLongerThanTheLimitIsALostLinkAt3s() throws {
        try start(.screenTurns)
        hand.press(.upper)
        hand.move(to: SIMD3(0, 0, -0.01), in: 0.5)
        XCTAssertTrue(hand.wait(1, until: { heldLive(1) }), "the hold did not go live")
        let index = model.cueLog.count
        path.stall()
        var lostAt: Date?
        _ = hand.wait(
            6,
            until: {
                if lostAt == nil, !model.session.state.connected { lostAt = Date() }
                return false
            })
        path.resume()
        hand.release(.upper)
        let lost = try XCTUnwrap(lostAt, "a 6 s stall did not lose the link")
        // During a hold the control connection hears only the echoes of its probes, twice a second, so its own 3 s
        // run out first.
        let control = lost.timeIntervalSince(try XCTUnwrap(path.lastDelivered[1]))
        let either = lost.timeIntervalSince(try XCTUnwrap(path.lastDelivered.values.max()))
        print(
            String(
                format: "STALL long: lost %.2f s after the control connection's last message, %.2f s after either's",
                control, either))
        XCTAssertGreaterThan(control, 2.99, "lost before the 3 s limit")
        XCTAssertLessThan(control, 4.0, "lost long after the 3 s limit")
        XCTAssertTrue(model.session.state.connectionLost)
        XCTAssertEqual(model.session.route, .s1, "a lost link on standby opens Connect")
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertEqual(
            cues(from: index).map(\.event).filter { if case .linkLost = $0 { return true } else { return false } },
            [.linkLost(holdEngaged: true)])
        XCTAssertTrue(model.debugLog.contains { $0.contains("link: lost (server went quiet)") })
    }

    // MARK: STOP during a short stall

    /// STOP pressed while the path holds everything back: the phone latches the stop at once and shows STOPPED, sends no
    /// command but the estop (its probes go on), and the server takes the estop when the path comes back.
    func testAStopPressedDuringAShortStallReachesTheServerWhenThePathComesBack() throws {
        try start(.screenTurns)
        hand.press(.upper)
        hand.move(to: SIMD3(0, 0, -0.01), in: 0.5)
        XCTAssertTrue(hand.wait(1, until: { heldLive(1) }), "the hold did not go live")
        let index = model.cueLog.count
        path.stall()
        _ = hand.wait(0.5, until: { false })
        hand.tap(x: hand.bottomBand.x, y: hand.bottomBand.y)
        XCTAssertTrue(model.session.state.emergencyStop)
        XCTAssertEqual(model.operating.state, .stopped(cause: .button))
        _ = hand.wait(1.3, until: { false })
        XCTAssertFalse(serverStopped, "nothing reached the server during the stall")
        XCTAssertTrue(model.session.state.connected, "a 1.8 s stall is not a lost link")
        XCTAssertEqual(model.operating.state, .stopped(cause: .button), "the phone kept showing the stop")
        path.resume()
        hand.release(.upper)
        XCTAssertTrue(hand.wait(2, until: { serverStopped }), "STOP did not reach the server when the path came back")
        hand.pump(1)
        XCTAssertEqual(model.operating.state, .stopped(cause: .button))
        XCTAssertTrue(model.session.state.connected)
        let after = cues(from: index).map(\.event)
        XCTAssertEqual(
            after.filter { if case .emergencyStop = $0 { return true } else { return false } }.count, 1, "\(after)")
        XCTAssertFalse(after.contains { if case .linkLost = $0 { return true } else { return false } }, "\(after)")
        print("STALL stop: cues \(after), the screen showed \(shownNames)")
    }

    // MARK: STOP and a lost link

    private static func isLinkLost(_ entry: CueLogEntry) -> Bool {
        if case .linkLost = entry.event { return true } else { return false }
    }

    private static func isAlarm(_ entry: CueLogEntry) -> Bool {
        if case .emergencyStop = entry.event { return true } else { return false }
    }

    private static func isRefusal(_ entry: CueLogEntry) -> Bool {
        if case .refused = entry.event { return true } else { return false }
    }

    /// STOP on the bottom band, as a thumb taps it.
    private func tapStop() { hand.tap(x: hand.bottomBand.x, y: hand.bottomBand.y) }

    /// Waits for the stalled path to lose the link, then lets it come back. True when the link was lost.
    private func waitForTheLinkToGo(_ what: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let lost = hand.wait(4.5, until: { !model.session.state.connected })
        path.resume()
        XCTAssertTrue(lost, "\(what): the stall did not lose the link", file: file, line: line)
        return lost
    }

    /// The operator connects again (Settings, Server, Connect) and the link comes up. Returns the number of the new
    /// control connection, to read what the app sent on it.
    private func connectAgain(_ what: String, file: StaticString = #filePath, line: UInt = #line) -> Int {
        let control = path.opened + 1
        model.connect()
        XCTAssertTrue(
            hand.wait(5, until: { model.session.state.connected }), "\(what): could not connect again", file: file,
            line: line)
        return control
    }

    /// A new run of the server, not stopped, at a new address: the operator's Connect reaches it.
    private func restartTheServer() throws {
        server.stop()
        var config = ServerModelConfig.s4Simulator(stepsPerSecond: 60)
        config.session = "00000000-0000-4000-8000-000000000002"
        server = LocalTeleopServer(config: config)
        try server.start()
        model.session.state.serverAddress = server.address
    }

    /// The first message on the new connection after its hello is `estop`, and the server is stopped within 2 s.
    private func checkTheStopWentOutFirst(
        on control: Int, _ what: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            Array((path.sent[control] ?? []).prefix(2)), ["hello", "estop"], "\(what): what went out first",
            file: file, line: line)
        XCTAssertTrue(
            hand.wait(2, until: { serverStopped }), "\(what): the server is not stopped 2 s after the welcome",
            file: file,
            line: line)
    }

    /// The STOP is owed and the operator is told without the screen: the link-lost sound and "Link lost.", then three
    /// ticks and "No link. Not stopped.", neither dropped. The screen shows the lost link, not STOPPED, in both
    /// languages, practice is refused because a STOP is waiting to reach the robot, and a press says "No link.".
    private func checkTheStopIsOwed(
        since index: Int, _ what: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let after = cues(from: index)
        let lost = after.firstIndex(where: Self.isLinkLost)
        let told = after.firstIndex { $0.event == .refused(.notStopped) }
        XCTAssertNotNil(lost, "\(what): no link-lost cue in \(after.map(\.event))", file: file, line: line)
        XCTAssertNotNil(
            told, "\(what): not told the STOP reached no robot: \(after.map(\.event))", file: file, line: line)
        if let lost, let told {
            XCTAssertLessThan(lost, told, "\(what): \(after.map(\.event))", file: file, line: line)
            XCTAssertEqual(
                after[lost].event, .linkLost(holdEngaged: false), "\(what): the STOP ended every hold", file: file,
                line: line)
            XCTAssertEqual(after[lost].sound, .linkLost, "\(what)", file: file, line: line)
            XCTAssertEqual(after[lost].speech, [.linkLost], "\(what)", file: file, line: line)
            XCTAssertEqual(after[told].haptic, .no, "\(what)", file: file, line: line)
            XCTAssertEqual(after[told].speech, [.notStopped], "\(what)", file: file, line: line)
            XCTAssertFalse(after[told].dropped, "\(what): the refusal was dropped", file: file, line: line)
        }
        XCTAssertEqual(model.operating.state, .linkLost, "\(what): the screen", file: file, line: line)
        XCTAssertEqual(
            model.practiceBlockedReason, "settings.practice_blocked_unsent", "\(what)", file: file, line: line)
        let language = L10n.language
        defer { L10n.language = language }
        var spoken: [String] = []
        for each in [AppLanguage.en, .zhHant] {
            L10n.language = each
            let look = OperatingWords.look(model.operating)
            XCTAssertEqual(look.word, L10n.string("state.link_lost"), "\(what) (\(each))", file: file, line: line)
            XCTAssertEqual(
                look.details, [L10n.string("detail.connect_in_settings")], "\(what) (\(each))", file: file, line: line)
            XCTAssertNotEqual(look.word, "state.link_lost", "\(what): no words in \(each)", file: file, line: line)
            spoken.append(SpeechText.string(CueTable.phrases(for: .refused(.notStopped)), language: each))
        }
        XCTAssertEqual(spoken.first, "No link. Not stopped.", "\(what)", file: file, line: line)
        XCTAssertNotEqual(spoken.last, spoken.first, "\(what): the same words in Chinese", file: file, line: line)
        hand.press(.upper)
        XCTAssertEqual(
            model.cueLog.last?.event, .refused(.noLink), "\(what): a press while owed", file: file, line: line)
        hand.release(.upper)
    }

    /// STOP tapped 0.5 s into a stall that becomes a lost link: the estop never reached the server. It is owed, the
    /// operator is told, and after connecting again `estop` goes out first, with the alarm, and the screen says STOPPED.
    private func stopInAStallThatLosesTheLink(holding: Bool) throws {
        let what = holding ? "STOP during a hold" : "STOP"
        try start(.screenTurns)
        if holding {
            hand.press(.upper)
            hand.move(to: SIMD3(0, 0, -0.01), in: 0.5)
            XCTAssertTrue(hand.wait(1, until: { heldLive(1) }), "the hold did not go live")
        }
        let index = model.cueLog.count
        path.stall()
        _ = hand.wait(0.5, until: { false })
        tapStop()
        XCTAssertEqual(model.operating.state, .stopped(cause: .button), "the phone latches at once")
        XCTAssertEqual(cues(from: index).filter(Self.isAlarm).count, 1, "and sounds the alarm once")
        guard waitForTheLinkToGo(what) else { return }
        if holding { hand.release(.upper) }
        checkTheStopIsOwed(since: index, what)
        _ = hand.wait(1, until: { false })
        XCTAssertFalse(serverStopped, "\(what): nothing reached the server")

        let reconnected = model.cueLog.count
        let control = connectAgain(what)
        checkTheStopWentOutFirst(on: control, what)
        hand.pump(1)
        let after = cues(from: reconnected)
        XCTAssertEqual(
            after.filter(Self.isAlarm).map(\.event), [.emergencyStop(.button, takeDiscarded: false)], "\(what)")
        XCTAssertFalse(after.contains(where: Self.isRefusal), "\(what): \(after.map(\.event))")
        XCTAssertEqual(model.operating.state, .stopped(cause: .button), "\(what): the screen after the welcome")
        XCTAssertTrue(serverStopped, "\(what): the server stays stopped")
        print("STALL owed \(what): cues \(cues(from: index).map(\.event)), the screen showed \(shownNames)")
    }

    func testAStopPressedInAStallThatLosesTheLinkIsOwedAndGoesOutFirstAfterTheWelcome() throws {
        try stopInAStallThatLosesTheLink(holding: false)
    }

    func testAStopPressedDuringAHoldInAStallThatLosesTheLinkIsOwedAndGoesOutFirstAfterTheWelcome() throws {
        try stopInAStallThatLosesTheLink(holding: true)
    }

    /// STOP, confirmed by the server's state, and then a lost link: nothing is owed and the screen keeps saying
    /// STOPPED. Connecting again to the same, still stopped server sends `estop` again, and nothing a person can notice
    /// changes: no alarm, no refusal, the same screen.
    func testAConfirmedStopStaysStoppedThroughALostLinkAndIsSentAgainUnnoticed() throws {
        try start(.screenTurns)
        tapStop()
        XCTAssertTrue(hand.wait(2, until: { serverStopped }), "STOP did not reach the server")
        hand.pump(1)
        let index = model.cueLog.count
        path.stall()
        guard waitForTheLinkToGo("confirmed") else { return }
        let lost = cues(from: index)
        XCTAssertEqual(lost.map(\.event), [.linkLost(holdEngaged: false)], "only the lost link is told")
        XCTAssertEqual(model.operating.state, .stopped(cause: .button), "the robot is stopped, as the server said")
        XCTAssertEqual(model.practiceBlockedReason, "settings.practice_blocked")

        let reconnected = model.cueLog.count
        shown = [model.operating.state]
        let control = connectAgain("confirmed")
        checkTheStopWentOutFirst(on: control, "confirmed")
        hand.pump(1)
        XCTAssertEqual(cues(from: reconnected).map(\.event), [], "nothing a person can notice")
        XCTAssertEqual(shown, [.stopped(cause: .button)], "the same screen throughout")
        XCTAssertTrue(model.debugLog.contains { $0.contains("the stop is latched, so estop is sent again") })
        XCTAssertTrue(serverStopped)
    }

    /// The same, but the server restarted while the link was down and its new run is not stopped: the welcome's
    /// `estop` stops it, with no second alarm.
    func testAConfirmedStopReachesARestartedServerWithoutASecondAlarm() throws {
        try start(.screenTurns)
        tapStop()
        XCTAssertTrue(hand.wait(2, until: { serverStopped }), "STOP did not reach the server")
        hand.pump(1)
        path.stall()
        guard waitForTheLinkToGo("restarted") else { return }
        try restartTheServer()
        XCTAssertFalse(serverStopped, "the new run starts unstopped")

        let reconnected = model.cueLog.count
        let control = connectAgain("restarted")
        checkTheStopWentOutFirst(on: control, "restarted")
        hand.pump(1)
        let after = cues(from: reconnected)
        XCTAssertFalse(after.contains(where: Self.isAlarm), "a second alarm: \(after.map(\.event))")
        XCTAssertFalse(after.contains(where: Self.isRefusal), "\(after.map(\.event))")
        XCTAssertEqual(model.operating.state, .stopped(cause: .button))
        XCTAssertTrue(serverStopped)
    }

    /// A stop that came from the server (another client's `estop`), then a lost link and a restarted server: the
    /// welcome's `estop` stops the new run too, with no second alarm.
    func testAStopFromTheServerReachesARestartedServerWithoutASecondAlarm() throws {
        try start(.screenTurns)
        server.inspect { sim in
            let other = sim.open()
            _ = sim.receive(
                #"{"v":1,"type":"hello","ts":0,"seq":1,"payload":{"client":"phone","name":"another client"}}"#,
                from: other, at: sim.time)
            _ = sim.receive(#"{"v":1,"type":"estop","ts":0,"seq":2,"payload":{}}"#, from: other, at: sim.time)
        }
        XCTAssertTrue(hand.wait(2, until: { model.session.state.emergencyStop }), "the phone did not latch the stop")
        XCTAssertEqual(model.operating.state, .stopped(cause: .other))
        XCTAssertFalse(path.sent[1]?.contains("estop") ?? true, "the phone does not echo the server's stop")
        hand.pump(1)
        path.stall()
        guard waitForTheLinkToGo("server's stop") else { return }
        XCTAssertEqual(model.operating.state, .stopped(cause: .other))
        try restartTheServer()

        let reconnected = model.cueLog.count
        let control = connectAgain("server's stop")
        checkTheStopWentOutFirst(on: control, "server's stop")
        hand.pump(1)
        let after = cues(from: reconnected)
        XCTAssertFalse(after.contains(where: Self.isAlarm), "a second alarm: \(after.map(\.event))")
        XCTAssertFalse(after.contains(where: Self.isRefusal), "\(after.map(\.event))")
        XCTAssertEqual(model.operating.state, .stopped(cause: .other))
        XCTAssertTrue(serverStopped)
    }

    /// A STOP owed after a lost link and then released (what Release, keep scene sends) before connecting again is no
    /// longer wanted: nothing is owed and no `estop` goes out after the welcome.
    func testAnOwedStopReleasedBeforeConnectingAgainIsNotSent() throws {
        try start(.screenTurns)
        path.stall()
        _ = hand.wait(0.5, until: { false })
        tapStop()
        guard waitForTheLinkToGo("released") else { return }
        XCTAssertEqual(model.operating.state, .linkLost)
        model.send(.releaseStop)
        XCTAssertFalse(model.session.state.emergencyStop)

        let control = connectAgain("released")
        // Past the second the screen shows the refusal heard at the lost link.
        _ = hand.wait(1.5, until: { false })
        XCTAssertFalse(path.sent[control]?.contains("estop") ?? true, "an estop went out: \(path.sent[control] ?? [])")
        XCTAssertFalse(serverStopped)
        XCTAssertEqual(model.operating.state, .ready)
    }

    /// The server took the `estop`, but the path stalled before its answer came back, and the link was lost: the
    /// phone cannot know, so the STOP is owed and the operator told, and after connecting again `estop` goes out once
    /// more, the server stays stopped, and the alarm and STOPPED are true.
    func testAStopTheServerTookButNeverConfirmedIsOwedAndSentAgain() throws {
        try start(.screenTurns)
        let index = model.cueLog.count
        let band = hand.bottomBand
        let touch = hand.touchDown(x: band.x, y: band.y)
        // The estop has left; everything after it, the server's answer included, waits in the path.
        path.stall()
        hand.touchUp(touch, x: band.x, y: band.y)
        XCTAssertTrue(hand.wait(1, until: { serverStopped }), "the server did not take the estop")
        guard waitForTheLinkToGo("unconfirmed") else { return }
        checkTheStopIsOwed(since: index, "unconfirmed")
        XCTAssertTrue(serverStopped)

        let reconnected = model.cueLog.count
        let control = connectAgain("unconfirmed")
        checkTheStopWentOutFirst(on: control, "unconfirmed")
        hand.pump(1)
        XCTAssertEqual(
            cues(from: reconnected).filter(Self.isAlarm).map(\.event), [.emergencyStop(.button, takeDiscarded: false)])
        XCTAssertEqual(model.operating.state, .stopped(cause: .button))
        XCTAssertTrue(serverStopped)
    }

    /// Released and pressed again inside the two seconds after `estop_reset`, while states the server sent before the
    /// release (saying stopped) are still on their way: they reach the phone after the second press but do not confirm
    /// it, so when the link is lost before the server's answer comes, that STOP is owed.
    func testAStateFromBeforeAReleaseDoesNotConfirmTheNextStop() throws {
        try start(.screenTurns)
        tapStop()
        XCTAssertTrue(hand.wait(2, until: { serverStopped }), "STOP did not reach the server")
        hand.pump(1)
        XCTAssertTrue(OperatingWords.offersRelease(model.operating), "Release, keep scene is offered")
        path.stall()
        // States saying stopped pile up in the path.
        _ = hand.wait(0.5, until: { false })
        model.send(.releaseStop)
        XCTAssertFalse(model.session.state.emergencyStop)
        _ = hand.wait(0.2, until: { false })
        let index = model.cueLog.count
        tapStop()
        XCTAssertTrue(model.session.state.emergencyStop)
        // For an instant the path lets everything held through: the old states reach the phone, the release and the
        // STOP leave for the server. It stalls again before the server's answers can come back.
        path.resume()
        path.stall()
        guard waitForTheLinkToGo("pressed again") else { return }
        checkTheStopIsOwed(since: index, "pressed again")

        let control = connectAgain("pressed again")
        checkTheStopWentOutFirst(on: control, "pressed again")
        hand.pump(1)
        XCTAssertEqual(model.operating.state, .stopped(cause: .button))
    }
}
