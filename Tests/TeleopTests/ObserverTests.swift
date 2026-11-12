import simd
import TeleopCore
import TeleopServerHost
import TeleopServerModel
import XCTest
@testable import Teleop

/// A real socket that writes down everything it sends and receives, in one log shared by both connections.
private final class RecordingTransport: LinkTransport {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    let name: String
    private let inner: WebSocketTransport
    private let record: (_ name: String, _ outgoing: Bool, _ text: String) -> Void

    init(url: URL, name: String, record: @escaping (_ name: String, _ outgoing: Bool, _ text: String) -> Void) {
        self.name = name
        self.record = record
        inner = WebSocketTransport(url: url)
        // Weak: the socket can still deliver after the test has let go of the app.
        inner.onText = { [weak self] text in
            guard let self else { return }
            record(name, false, text)
            onText?(text)
        }
        inner.onClose = { [weak self] in self?.onClose?() }
    }

    func open() { inner.open() }

    func send(_ text: String) {
        record(name, true, text)
        inner.send(text)
    }

    func close() { inner.close() }

    /// The socket fails under the app, as a dropped Wi-Fi link does.
    func fail() {
        inner.close()
        onClose?()
    }
}

/// The listening connection, STOP on both connections and the reset procedure, over real sockets against the
/// server model on 127.0.0.1.
final class ObserverTests: XCTestCase {
    private struct Entry {
        let at: Date
        let connection: String
        let outgoing: Bool
        let type: String
        let payload: [String: Any]
    }

    private var server: LocalTeleopServer!
    private var position = SIMD3<Float>.zero
    private var log: [Entry] = []
    private var observers: [RecordingTransport] = []
    private var models: [AppModel] = []

    override func setUpWithError() throws {
        server = LocalTeleopServer()
        try server.start()
        log = []
        observers = []
    }

    override func tearDown() {
        for model in models { model.link.closeQuietly() }
        models = []
        server.stop()
        server = nil
        super.tearDown()
    }

    private func record(_ connection: String, _ outgoing: Bool, _ text: String) {
        guard let message = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        log.append(Entry(at: Date(), connection: connection, outgoing: outgoing, type: message["type"] as? String ?? "",
                         payload: message["payload"] as? [String: Any] ?? [:]))
    }

    private func makeModel() -> AppModel {
        let model = AppModel(
            start: .s1,
            haptics: NoHaptics(),
            pose: { [weak self] in TestPose.portrait(at: self?.position ?? .zero) },
            liveLink: true,
            makeTransport: { [weak self] url in
                RecordingTransport(url: url, name: "control") { self?.record($0, $1, $2) }
            },
            makeObserverTransport: { [weak self] url in
                let made = RecordingTransport(url: url, name: "observer") { self?.record($0, $1, $2) }
                self?.observers.append(made)
                return made
            },
            clientName: "teleop-ios/2.3.4 (56)"
        )
        model.session.state.serverAddress = server.address
        models.append(model)
        return model
    }

    private func wait(_ seconds: TimeInterval, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if done() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return done()
    }

    private func pump(_ seconds: TimeInterval) { _ = wait(seconds, until: { false }) }

    /// Connected, with the listening connection up.
    private func connected() throws -> AppModel {
        let model = makeModel()
        model.connect()
        XCTAssertTrue(wait(3, until: { model.session.state.connected }), "no link")
        XCTAssertTrue(wait(3, until: { model.link.observerUp }), "the listening connection did not come up")
        return try XCTUnwrap(model)
    }

    /// Moves the phone forward by `metres` over `seconds`, 30 steps a second, well under the speed limit.
    private func move(forward metres: Float, over seconds: Double) {
        let from = position
        let steps = Int(seconds * 30)
        for step in 1...steps {
            position = from + SIMD3(0, 0, -metres * Float(step) / Float(steps))
            pump(1.0 / 30)
        }
    }

    private func entries(_ connection: String, incoming type: String, from start: Date, to end: Date) -> [Entry] {
        log.filter { $0.connection == connection && !$0.outgoing && $0.type == type && $0.at >= start && $0.at <= end }
    }

    func testTheListeningConnectionHearsEveryHoldTheControlConnectionDoesNot() throws {
        let model = try connected()
        model.send(.holdArmStart)
        XCTAssertTrue(model.session.state.armMoving)
        let start = Date()
        move(forward: 0.02, over: 1.5)
        let end = Date()
        model.send(.holdArmEnd)
        // The first 300 ms may still carry a state sent just before the hold began.
        let window = start.addingTimeInterval(0.3)
        // The server sends a connection a state only after 200 ms with nothing from it. A busy test machine can
        // pause the app's 30 Hz stream that long; each such pause may earn one state, and nothing else may.
        let sentOnControl = log.filter { $0.connection == "control" && $0.outgoing && $0.at >= start && $0.at <= end }.map(\.at)
        let pauses = zip(sentOnControl, sentOnControl.dropFirst()).filter { $1.timeIntervalSince($0) >= 0.18 }.count
        XCTAssertLessThanOrEqual(entries("control", incoming: "state", from: window, to: end).count, pauses,
                                 "the control connection streams, so the server sends it no state")
        XCTAssertGreaterThanOrEqual(entries("observer", incoming: "state", from: window, to: end).count, 5,
                                    "the listening connection gets one every 200 ms")
        let hello = log.first { $0.connection == "observer" && $0.outgoing }
        XCTAssertEqual(hello?.type, "hello")
        XCTAssertEqual(hello?.payload["name"] as? String, "teleop-ios/2.3.4 (56) observer")
        XCTAssertEqual(log.filter { $0.connection == "observer" && $0.outgoing }.count, 1, "it only listens")
    }

    /// The listening connection owns nothing: losing it mid-hold stops nothing, and it comes back by itself.
    func testClosingTheListeningConnectionMidHoldStopsNothing() throws {
        let model = try connected()
        model.send(.holdArmStart)
        move(forward: 0.01, over: 0.5)
        let first = try XCTUnwrap(observers.last)
        first.fail()
        let armAtDrop = server.inspect { $0.world.arm }
        move(forward: 0.02, over: 1.0)
        XCTAssertTrue(model.session.state.armMoving, "the operator's hold goes on")
        XCTAssertEqual(server.inspect { $0.state["estop"] }, false, "the server did not stop")
        XCTAssertEqual(server.inspect { $0.state["ik"]?.stringValue }, "pose_tracking", "the server's hold goes on")
        XCTAssertLessThan(server.inspect { $0.world.arm.y } - armAtDrop.y, -0.01, "and the arm still follows")
        model.send(.holdArmEnd)
        XCTAssertTrue(wait(2, until: { !log.filter { $0.connection == "control" && $0.payload["reason"] as? String == "pose_stopped" }.isEmpty }))
        XCTAssertFalse(log.contains { $0.payload["reason"] as? String == "pose_watchdog_timeout" })
        XCTAssertTrue(model.session.state.connected)
        XCTAssertTrue(wait(4, until: { observers.count == 2 && model.link.observerUp }), "the listening connection did not come back")
    }

    func testStopReachesTheServerOnBothConnections() throws {
        let model = try connected()
        model.send(.stop)
        XCTAssertEqual(model.session.route, .s4)
        for connection in ["control", "observer"] {
            XCTAssertTrue(log.contains { $0.connection == connection && $0.outgoing && $0.type == "estop" }, "no estop on \(connection)")
            XCTAssertTrue(wait(2, until: {
                log.contains { $0.connection == connection && !$0.outgoing && $0.payload["reason"] as? String == "estop_engaged" }
            }), "the server did not take the estop on \(connection)")
        }
        XCTAssertEqual(server.inspect { $0.state["estop"] }, true)
    }

    /// Released and reset at once: the reset waits for the hold's final ack, so the server takes it.
    func testAResetPressedRightAfterAHoldGoesOutAfterTheFinalAckAndSucceeds() throws {
        let model = try connected()
        let episode = server.inspect { $0.episode }
        model.send(.holdArmStart)
        move(forward: 0.02, over: 0.8)
        model.send(.holdArmEnd)
        model.send(.resetScene)
        XCTAssertTrue(wait(5, until: { log.contains { $0.connection == "control" && $0.payload["reason"] as? String == "scene_reset" } }),
                      "the scene was not reset")
        let control = log.filter { $0.connection == "control" }
        let finalAck = try XCTUnwrap(control.firstIndex { !$0.outgoing && $0.payload["reason"] as? String == "pose_stopped" })
        let reset = try XCTUnwrap(control.firstIndex { $0.outgoing && $0.type == "reset_scene" })
        XCTAssertGreaterThan(reset, finalAck, "reset_scene went out before the hold's final ack")
        XCTAssertFalse(control.contains { $0.payload["reason"] as? String == "busy" })
        XCTAssertEqual(control.filter { $0.outgoing && $0.type == "reset_scene" }.count, 1)
        XCTAssertTrue(wait(2, until: { server.inspect { $0.episode } == episode + 1 }))
    }

    func testAResetPressedWhileTheArmIsHeldIsRefused() throws {
        let model = try connected()
        model.send(.holdArmStart)
        move(forward: 0.01, over: 0.3)
        model.send(.resetScene)
        XCTAssertTrue(model.session.state.armMoving)
        model.send(.holdArmEnd)
        pump(0.5)
        XCTAssertFalse(log.contains { $0.outgoing && $0.type == "reset_scene" })
    }
}
