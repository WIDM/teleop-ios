import TeleopCore
import XCTest
@testable import TeleopServerModel

/// The app's real `TeleopLink` against the server model, in one process, on a clock the test moves in 1 ms steps.
/// Messages take 1 ms each way, so nothing is answered inside the call that sent it.
private final class Wire {
    let model: ServerModel
    let connection: Int
    private(set) var link: TeleopLink!
    private(set) var time = 0.0
    private let latency = 0.001
    private var toServer: [(at: Double, text: String)] = []
    private var toLink: [(at: Double, output: ServerOutput)] = []
    /// What the link reported, in order.
    private(set) var events: [LinkEvent] = []
    /// What the server sent, in order.
    private(set) var fromServer: [ServerOutput] = []
    /// What the link sent, in order, with the time it went out.
    private(set) var sent: [(time: Double, message: JSONValue)] = []

    init(config: ServerModelConfig = .s4Simulator) {
        model = ServerModel(config: config)
        connection = model.open()
        link = TeleopLink(
            send: { [unowned self] text in
                sent.append((time, JSONValue.parse(text) ?? .null))
                toServer.append((time + latency, text))
            },
            now: { [unowned self] in Int((time * 1000).rounded()) }
        )
        link.hello(name: "test")
        run(0.5)
    }

    /// Moves time on by `seconds`. `tick` runs every 1/30 s, as the app's link timer does.
    func run(_ seconds: Double, tick: (() -> Void)? = nil) {
        let end = time + seconds
        var nextTick = time
        while time < end - 1e-9 {
            if let tick, time >= nextTick - 1e-9 {
                tick()
                nextTick += 1.0 / 30
            }
            time = min(time + 0.001, end)
            schedule(model.advance(to: time))
            while let first = toServer.first, first.at <= time + 1e-9 {
                toServer.removeFirst()
                schedule(model.receive(first.text, from: connection, at: time))
            }
            while let first = toLink.first, first.at <= time + 1e-9 {
                toLink.removeFirst()
                fromServer.append(first.output)
                if let event = link.receive(first.output.text) { events.append(event) }
            }
        }
    }

    private func schedule(_ outputs: [ServerOutput]) {
        toLink += outputs.map { (time + latency, $0) }
    }

    func acks(_ reason: String) -> [ServerOutput] {
        fromServer.filter { $0.type == "ack" && $0.payload["reason"]?.stringValue == reason }
    }

    func sentTimes(_ type: String) -> [Double] { sent.filter { $0.message["type"] == .string(type) }.map(\.time) }

    func ackTime(_ reason: String) -> Double? { acks(reason).first?.time }
}

final class LinkTests: XCTestCase {
    private let params = PoseParams(gain: 1, smoothing: 0)

    func testTheLinkComesUpOnTheModel() {
        let wire = Wire()
        XCTAssertTrue(wire.link.ready)
        XCTAssertEqual(wire.events.first, .up(estop: false, gripper: .closed))
        XCTAssertNotNil(wire.link.lastEndEffector)
    }

    /// The arm released and the gripper pressed at once, as the app does: the link must hold the gripper's start
    /// back until the server's final ack for the arm hold, or the server refuses it `busy`.
    func testAStartRightAfterAStopWaitsForTheFinalAckAndIsAccepted() throws {
        let wire = Wire()
        XCTAssertTrue(wire.link.poseStart(params))
        wire.run(0.5) { wire.link.poseUpdate(positionMeters: [0, 0.01, 0]) }
        wire.link.poseStop()
        wire.link.gripperJogStart(.open)
        wire.run(1.0) { wire.link.keepalive() }
        XCTAssertEqual(wire.acks("busy").count, 0, "the server refused the gripper start")
        let finished = try XCTUnwrap(wire.ackTime("pose_stopped"))
        let started = try XCTUnwrap(wire.sentTimes("gripper_jog_start").first)
        XCTAssertGreaterThan(started, finished, "the start went out before the old hold had finished")
        XCTAssertTrue(wire.link.gripperJogActive)
        XCTAssertEqual(wire.model.state["ik"], "gripper_jogging")
    }

    /// Gripper, wrist turn, gripper, arm: each takes over from the one before while it is still held.
    func testEachControlTakesOverFromTheOneStillHeld() {
        let wire = Wire()
        wire.link.gripperJogStart(.open)
        wire.run(0.6) { wire.link.keepalive() }
        XCTAssertTrue(wire.link.orientStart())
        wire.run(0.6) { wire.link.orientUpdate(rollDegrees: 10) }
        wire.link.gripperJogStart(.closed)
        wire.run(0.6) { wire.link.keepalive() }
        XCTAssertTrue(wire.link.poseStart(params))
        wire.run(0.6) { wire.link.poseUpdate(positionMeters: [0, 0, 0]) }
        wire.link.poseStop()
        wire.run(0.5)
        XCTAssertEqual(wire.acks("busy").count, 0)
        XCTAssertEqual(
            wire.fromServer.filter { $0.type == "ack" && $0.payload["status"] == "ok" }.compactMap { $0.payload["reason"]?.stringValue }
                .filter { $0.hasSuffix("_stopped") },
            ["gripper_jog_stopped", "orient_stopped", "gripper_jog_stopped", "pose_stopped"]
        )
        XCTAssertFalse(wire.events.contains { if case .holdRefused = $0 { return true } else { return false } })
    }

    /// A reset asked for right after the stop of a running hold. The server refuses a reset behind an unfinished
    /// hold (`busy`), so the link holds it back until the hold's final ack; then the scene resets.
    func testAResetRightBehindAStopWaitsForTheFinalAckAndResets() throws {
        let wire = Wire()
        let episode = wire.model.episode
        wire.link.poseStart(params)
        wire.run(0.5) { wire.link.poseUpdate(positionMeters: [0, 0.01, 0]) }
        XCTAssertFalse(wire.link.resetScene(), "refused while the arm is held")
        wire.link.poseStop()
        XCTAssertTrue(wire.link.resetScene())
        wire.run(3) { wire.link.service() }
        XCTAssertEqual(wire.acks("busy").count, 0)
        let finished = try XCTUnwrap(wire.ackTime("pose_stopped"))
        let reset = try XCTUnwrap(wire.sentTimes("reset_scene").first)
        XCTAssertGreaterThan(reset, finished, "the reset went out before the hold had finished")
        XCTAssertEqual(wire.acks("scene_reset").count, 1)
        XCTAssertTrue(wire.events.contains(.resetDone))
        XCTAssertEqual(wire.acks("pose_watchdog_timeout").count, 0)
        XCTAssertEqual(wire.model.episode, episode + 1)
        XCTAssertFalse(wire.link.holdActive)
    }

    func testAHoldTheAppStopsFeedingEndsByWatchdogAndTheLinkLetsGo() {
        let wire = Wire()
        wire.link.poseStart(params)
        wire.run(0.2) { wire.link.poseUpdate(positionMeters: [0, 0, 0]) }
        wire.run(1.0)
        XCTAssertTrue(wire.events.contains(.holdRefused(reason: "pose_watchdog_timeout")))
        XCTAssertFalse(wire.link.holdActive)
        XCTAssertEqual(wire.model.state["estop"], false)
    }

    func testKeepalivesKeepAGripperJogAliveForAsLongAsTheyCome() {
        let wire = Wire()
        wire.link.gripperJogStart(.open)
        var ticks = 0
        wire.run(3) {
            ticks += 1
            // The app sends one about every 150 ms.
            if ticks % 5 == 0 { wire.link.keepalive() }
        }
        XCTAssertTrue(wire.link.gripperJogActive)
        XCTAssertFalse(wire.events.contains { if case .gripperRefused = $0 { return true } else { return false } })
        XCTAssertEqual(wire.model.state["gripper"], "open")
    }

    func testAfterAnEmergencyStopStartsAreRefusedUntilItIsReset() {
        let wire = Wire()
        wire.link.poseStart(params)
        wire.run(0.3) { wire.link.poseUpdate(positionMeters: [0, 0, 0]) }
        wire.link.estop()
        wire.run(0.3)
        XCTAssertEqual(wire.acks("estop_engaged").count, 1)
        XCTAssertEqual(wire.events.last { if case .state = $0 { return true } else { return false } }, .state(estop: true, gripper: .closed))
        XCTAssertTrue(wire.link.poseStart(params))
        wire.run(0.3) { wire.link.poseUpdate(positionMeters: [0, 0, 0]) }
        XCTAssertTrue(wire.events.contains(.holdRefused(reason: "estop_active")))
        XCTAssertFalse(wire.link.holdActive)
        wire.link.estopReset()
        wire.run(0.3)
        XCTAssertEqual(wire.acks("estop_reset").count, 1)
        XCTAssertTrue(wire.link.poseStart(params))
        wire.run(0.5) { wire.link.poseUpdate(positionMeters: [0, 0.01, 0]) }
        XCTAssertTrue(wire.link.holdActive)
        XCTAssertEqual(wire.model.state["ik"], "pose_tracking")
    }
}
