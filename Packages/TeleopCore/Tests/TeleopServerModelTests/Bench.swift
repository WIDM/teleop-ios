import Foundation
import XCTest
@testable import TeleopServerModel

/// A model and its clients on one clock the test moves. Nothing waits for real time.
final class Bench {
    let model: ServerModel
    private(set) var now = 0.0
    fileprivate var inboxes: [Int: [ServerOutput]] = [:]

    init(_ config: ServerModelConfig = .s4Simulator) {
        model = ServerModel(config: config)
    }

    var config: ServerModelConfig { model.config }
    /// Wall-clock time of one loop pass.
    var stepTime: Double { 1 / config.stepsPerSecond }

    func client(hello: Bool = true) -> Client {
        let client = Client(bench: self, id: model.open())
        if hello { client.send("hello", .object(["client": "phone", "name": "bench"])) }
        return client
    }

    func wait(_ seconds: Double) {
        now += seconds
        deliver(model.advance(to: now))
    }

    fileprivate func deliver(_ outputs: [ServerOutput]) {
        for output in outputs { inboxes[output.connection, default: []].append(output) }
    }

    final class Client {
        unowned let bench: Bench
        let id: Int
        private(set) var seq = 0

        fileprivate init(bench: Bench, id: Int) {
            self.bench = bench
            self.id = id
        }

        /// Everything this client has been sent so far, in order.
        var received: [ServerOutput] { bench.inboxes[id] ?? [] }
        var states: [ServerOutput] { received.filter { $0.type == "state" } }
        var lastState: JSONValue { states.last?.payload ?? .null }

        func received(after time: Double) -> [ServerOutput] { received.filter { $0.time > time } }

        @discardableResult
        func send(_ type: String, _ payload: JSONValue = .object([])) -> Int {
            seq += 1
            let message = JSONValue.object(["v": 1, "type": .string(type), "ts": 0, "seq": .int(seq), "payload": payload])
            sendText(message.text)
            return seq
        }

        func sendText(_ text: String) {
            bench.deliver(bench.model.receive(text, from: id, at: bench.now))
        }

        func close() {
            bench.deliver(bench.model.close(id, at: bench.now))
        }

        /// The ack for `seq`, if it has come.
        func ack(_ seq: Int) -> (status: String, reason: String, time: Double)? {
            guard let output = received.first(where: { $0.type == "ack" && $0.payload["seq"]?.intValue == seq }) else {
                return nil
            }
            return (output.payload["status"]?.stringValue ?? "", output.payload["reason"]?.stringValue ?? "", output.time)
        }

        func reason(_ seq: Int) -> String? { ack(seq).map { "\($0.status) \($0.reason)" } }

        /// The state that came with the ack for `seq` (the very next message, with the same seq), if one did.
        func stateWithAck(_ seq: Int) -> JSONValue? {
            let all = received
            guard let index = all.firstIndex(where: { $0.type == "ack" && $0.payload["seq"]?.intValue == seq }),
                  index + 1 < all.count, all[index + 1].type == "state",
                  all[index + 1].message["seq"]?.intValue == seq else { return nil }
            return all[index + 1].payload
        }

        // MARK: Controls, as a phone app sends them

        static let poseParameters: JSONValue = .object([
            "frame": "webxr_local", "rate_hz": 30, "control_mode": "translation", "gain": 1.0, "deadband_deg": 0.0,
            "smoothing": 0.0,
        ])

        @discardableResult
        func poseStart(mode: String = "translation") -> Int {
            send("pose_start", Self.poseParameters.setting("control_mode", .string(mode)))
        }

        /// A pose update asking the arm to go `base` metres (robot base frame) from where the hold began.
        func poseUpdate(base: SIMD3<Double>, gripperDelta: Double = 0, q: [Double] = [0, 0, 0, 1]) {
            send("pose_update", .object([
                "p_rel_m": .numbers([base.x, base.y, -base.z]), "q_rel": .numbers(q), "gripper_delta": .double(gripperDelta),
            ]))
        }

        @discardableResult
        func orientStart() -> Int {
            send("orient_start", .object([
                "frame": "phone_body", "rate_hz": 30, "gain": 1.0, "deadband_deg": 0.0, "smoothing": 0.0,
            ]))
        }

        /// Sends `message` every `interval` seconds for `seconds`, as a phone streams a held control.
        func stream(for seconds: Double, every interval: Double = 1.0 / 30, _ message: () -> Void) {
            let end = bench.now + seconds
            while bench.now < end - 1e-9 {
                message()
                bench.wait(min(interval, end - bench.now))
            }
        }

        /// One pose hold that moves the arm to `target` (base frame), then ends it and waits for the final ack.
        @discardableResult
        func moveArm(to target: SIMD3<Double>, seconds: Double = 2.5) -> (status: String, reason: String, time: Double)? {
            let from = bench.model.world.arm
            let start = poseStart()
            stream(for: seconds) { poseUpdate(base: target - from) }
            send("pose_stop")
            bench.wait(0.3)
            return ack(start)
        }

        /// A gripper jog held for `seconds` with keepalives, then released. Returns the start's seq.
        @discardableResult
        func gripperJog(_ action: String, seconds: Double, release: Bool = true) -> Int {
            let start = send("gripper_jog_start", .object(["action": .string(action), "step": "coarse"]))
            stream(for: seconds, every: 0.15) { send("jog_keepalive") }
            if release {
                send("gripper_jog_stop")
                bench.wait(0.3)
            }
            return start
        }

        /// Opens the jaws, brings the pinch point down to `offset` (base frame) from the cube's centre, closes the
        /// jaws until they stop, and says whether they took hold of the cube.
        func closeJaws(offFromCube offset: SIMD3<Double>) -> Bool {
            let config = bench.config
            let grasp = config.cubeStartWorld - config.baseInWorld - config.toolOffset + offset
            gripperJog("open", seconds: 2.5)
            moveArm(to: grasp + SIMD3(0, 0, 0.03))
            moveArm(to: grasp)
            gripperJog("close", seconds: 7)
            return bench.model.world.holdingCube
        }

        /// Picks the cube up and lowers it onto the goal the way an operator would: open, go to the grasp point,
        /// close until the jaws stop on the cube, lift, carry, lower. Leaves the jaws closed on the cube.
        func carryCubeOntoGoal(file: StaticString = #filePath, line: UInt = #line) {
            let config = bench.config
            let cube = config.cubeStartWorld - config.baseInWorld
            let grasp = cube - config.toolOffset
            let lift = SIMD3<Double>(0, 0, 0.03)
            gripperJog("open", seconds: 2.5)
            moveArm(to: grasp + lift)
            moveArm(to: grasp)
            gripperJog("close", seconds: 7)
            XCTAssertTrue(bench.model.world.holdingCube, "the jaws did not take hold of the cube", file: file, line: line)
            let overGoal = grasp + SIMD3(config.goalWorld.x - config.cubeStartWorld.x, config.goalWorld.y - config.cubeStartWorld.y, 0)
            moveArm(to: grasp + lift, seconds: 3)
            moveArm(to: overGoal + lift, seconds: 4)
            moveArm(to: overGoal + SIMD3(0, 0, 0.002), seconds: 3)
            XCTAssertTrue(bench.model.world.holdingCube, "the cube was dropped on the way", file: file, line: line)
        }
    }
}
