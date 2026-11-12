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
    private var opened = 0

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
    func send(_ text: String) { path.pass { [weak self] in self?.socket.send(text) } }
    func close() { socket.close() }
}

/// A stall of the network path, against the server model on a local socket with its real 750 ms watchdog. A stall
/// shorter than the link's limit costs the operator the hold the server's watchdog ends ("Link hiccup."), never the
/// session; a longer one is a lost link at 3 s. STOP pressed during a short stall reaches the server when the path
/// comes back.
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
        shown = [model.operating.state]
        stall(for: 1.8, "arm")
        XCTAssertTrue(hand.wait(1, until: { !model.session.state.armMoving }), "the hold did not end")
        // What the screen shows next, while the operator still holds.
        _ = hand.wait(0.5, until: { false })
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
        shown = [model.operating.state]
        stall(for: 1.8, "gripper")
        XCTAssertTrue(hand.wait(1, until: { model.session.state.gripperMoving == nil }), "the hold did not end")
        // What the screen shows next, while the operator still holds.
        _ = hand.wait(0.5, until: { false })
        model.buttonUp(.close)
        checkTheHoldEndedAndTheLinkStayed(
            since: index, reason: "gripper refused: gripper_jog_watchdog_timeout", "gripper")
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
        shown = [model.operating.state]
        stall(for: 1.8, "wrist")
        XCTAssertTrue(hand.wait(1, until: { !model.session.state.wristMoving }), "the hold did not end")
        // What the screen shows next, while the operator still holds.
        _ = hand.wait(0.5, until: { false })
        hand.touchUp(touch, x: point.x, y: point.y)
        checkTheHoldEndedAndTheLinkStayed(since: index, reason: "wrist hold refused: orient_watchdog_timeout", "wrist")
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

    /// STOP pressed while the path holds everything back: the phone latches the stop at once and shows STOPPED, sends
    /// nothing more, and the server takes the estop when the path comes back.
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
}
