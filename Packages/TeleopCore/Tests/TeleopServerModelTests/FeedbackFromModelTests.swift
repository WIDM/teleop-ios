import Foundation
import TeleopCore
import XCTest
@testable import TeleopServerModel

/// What `ServerOutput` says, as the app reads a `state`.
func serverState(_ output: ServerOutput) -> ServerState? {
    guard output.type == "state",
        let message = try? JSONSerialization.jsonObject(with: Data(output.text.utf8)) as? [String: Any],
        let payload = message["payload"] as? [String: Any]
    else { return nil }
    return ServerState(payload: payload)
}

/// Blocked and contact, judged by `FeedbackMonitor` from the states a second, listening connection gets from the
/// server model during the holds.
final class FeedbackFromModelTests: XCTestCase {
    private var bench: Bench!
    private var phone: Bench.Client!
    private var observer: Bench.Client!
    private var monitor = FeedbackMonitor(limits: GripperLimits(openDeg: 97, emptyDeg: 2))
    private var events: [(atMs: Int, event: FeedbackEvent)] = []
    private var read = 0

    override func setUp() {
        bench = Bench(.s4Simulator(stepsPerSecond: 17))
        phone = bench.client()
        observer = bench.client()
        monitor = FeedbackMonitor(limits: GripperLimits(openDeg: 97, emptyDeg: 2))
        events = []
        bench.wait(0.5)
        read = observer.received.count
    }

    private var nowMs: Int { Int((bench.now * 1000).rounded()) }

    /// Hands the monitor every state the listening connection got since the last call.
    private func pumpObserver() {
        let all = observer.received
        for output in all[read...] {
            guard let state = serverState(output) else { continue }
            let at = Int((output.time * 1000).rounded())
            events += monitor.observe(state, at: at).map { (at, $0) }
        }
        read = all.count
        events += monitor.tick(at: nowMs).map { (nowMs, $0) }
    }

    func testTheListeningConnectionHearsTheHoldTheControlConnectionDoesNot() {
        let since = bench.now
        phone.poseStart()
        phone.stream(for: 1.5) { phone.poseUpdate(base: .zero) }
        let during = { (client: Bench.Client) in
            client.received(after: since + 0.05).filter { $0.type == "state" && $0.time < since + 1.5 }.count
        }
        XCTAssertEqual(during(phone), 0, "the control connection gets no state while it streams")
        XCTAssertGreaterThanOrEqual(during(observer), 6, "the listening connection gets one every 200 ms")
    }

    /// From the reset pose the jaw tips reach the table 2.7 cm down. Asked for 5 cm, the arm stops there and the
    /// server says nothing about it; the monitor reports it blocked while the operator still holds.
    func testAnArmStoppedByTheTableIsBlocked() throws {
        let start = bench.model.world.arm
        let target = start + SIMD3(0, 0, -0.05)
        phone.poseStart()
        monitor.startSent(.pose, restart: false, at: nowMs)
        phone.stream(for: 4) {
            phone.poseUpdate(base: target - start)
            monitor.commanded(target)
            pumpObserver()
        }
        let blocked = try XCTUnwrap(events.first { $0.event == .limit(.blocked) }, "\(events)")
        XCTAssertEqual(events.filter { $0.event == .limit(.blocked) }.count, 1)
        XCTAssertEqual(bench.model.state["estop"], false)
        // The arm reaches the table within about a second at this pace; blocked follows a second of standing still.
        XCTAssertGreaterThan(Double(blocked.atMs) / 1000 - bench.now + 4, 1.0)
        XCTAssertLessThan(Double(blocked.atMs) / 1000 - bench.now + 4, 3.5)
        XCTAssertEqual(events.map(\.event).filter { $0 == .holdLive(hold: 1) }.count, 1)
    }

    func testAnArmMovingFreelyIsNeverBlocked() {
        let start = bench.model.world.arm
        let target = start + SIMD3(0.03, 0, 0.02)
        phone.poseStart()
        monitor.startSent(.pose, restart: false, at: nowMs)
        phone.stream(for: 3) {
            phone.poseUpdate(base: target - start)
            monitor.commanded(target)
            pumpObserver()
        }
        XCTAssertFalse(events.contains { $0.event == .limit(.blocked) }, "\(events)")
    }

    /// Jaws closed around the cube: contact while close is held, then gripping until an open. Closed on nothing:
    /// empty.
    func testClosingOnTheCubeGripsAndAnEmptyCloseSaysSo() throws {
        let config = bench.config
        let grasp = config.cubeStartWorld - config.baseInWorld - config.toolOffset
        phone.gripperJog("open", seconds: 2.5)
        phone.moveArm(to: grasp + SIMD3(0, 0, 0.03))
        phone.moveArm(to: grasp)
        read = observer.received.count

        let close = phone.send("gripper_jog_start", .object(["action": "close", "step": "coarse"]))
        monitor.startSent(.gripper(.closed), restart: false, at: nowMs)
        // The jaws close at 60 degrees a simulated second, 17 degrees a wall second at this pace.
        phone.stream(for: 7, every: 0.15) {
            phone.send("jog_keepalive")
            pumpObserver()
        }
        XCTAssertTrue(bench.model.world.holdingCube)
        XCTAssertEqual(events.map(\.event).filter { $0 == .contact }.count, 1, "\(events)")
        XCTAssertFalse(events.contains { $0.event == .limit(.empty) })
        XCTAssertTrue(monitor.gripping)
        phone.send("gripper_jog_stop")
        monitor.released()
        bench.wait(0.3)
        XCTAssertEqual(phone.reason(close), "ok gripper_jog_stopped")
        XCTAssertTrue(monitor.gripping, "still gripping after close is let go")

        // Open, lift away from the cube, close again on nothing.
        events = []
        phone.send("gripper_jog_start", .object(["action": "open", "step": "coarse"]))
        monitor.startSent(.gripper(.open), restart: false, at: nowMs)
        phone.stream(for: 2, every: 0.15) {
            phone.send("jog_keepalive")
            pumpObserver()
        }
        phone.send("gripper_jog_stop")
        monitor.released()
        XCTAssertFalse(monitor.gripping)
        XCTAssertTrue(events.contains { $0.event == .limit(.fullyOpen) }, "\(events)")
        bench.wait(0.3)
        phone.moveArm(to: grasp + SIMD3(0, 0, 0.04))
        read = observer.received.count
        events = []
        phone.send("gripper_jog_start", .object(["action": "close", "step": "coarse"]))
        monitor.startSent(.gripper(.closed), restart: false, at: nowMs)
        // The jaws close at 60 degrees a simulated second, 17 degrees a wall second at this pace.
        phone.stream(for: 7, every: 0.15) {
            phone.send("jog_keepalive")
            pumpObserver()
        }
        XCTAssertEqual(events.map(\.event).filter { $0 == .limit(.empty) }.count, 1, "\(events)")
        XCTAssertFalse(events.contains { $0.event == .contact })
        XCTAssertFalse(monitor.gripping)
    }
}
