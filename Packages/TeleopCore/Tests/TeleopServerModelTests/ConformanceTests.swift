import XCTest
@testable import TeleopServerModel

/// Every recording of the real server, replayed into the model at its recorded times, must come back the same
/// in what matters to a client:
///
/// - acks: for each client seq, the same status and reason, in the same order as the other acks (strict);
/// - the state that comes with an ack: there for the same acks, with the same `estop` and `ik` (strict);
/// - errors and `test` echoes: the same seqs and codes (strict);
/// - `state` timing: none while the client keeps sending at least every 200 ms, except right after an ack
///   (strict); in each longer silence, a state every 200 ms (counted, within one and the 2 % by which the real
///   server's broadcasts drift: it spends about 3 ms on each, measured over 452 of them);
/// - `state` fields: the same keys with the same JSON types, first and last in the scenario (strict);
/// - final `estop`, `ik`, `episode`, `gripper`, `step`, `task_success` and the recorder fields (strict).
///
/// Positions and times are compared loosely, because the model's arm is a point that does not lag, sag or bend
/// and the real loop's pace varies with what it is doing (13.8 to 19.1 steps a second by command kind on the day
/// of these recordings, against the model's steady 17): the arm must end up displaced the same way (within 45
/// degrees, when the real one moved more than a centimetre), wrist and jaw angles within 5 degrees, the cube within a
/// centimetre. An ack the server sends at once must come within 50 ms of the recorded one (the recordings carry
/// 8 to 26 ms of network delay); one that ends a hold, within 100 ms (one or two passes of the loop); one that ends
/// a command lasting a fixed number of steps, within 20 % of the recorded duration.
final class ConformanceTests: XCTestCase {
    func testS00Hello() throws { try check("s00_hello") }
    func testS01Idle() throws { try check("s01_idle") }
    func testS02PoseHold() throws { try check("s02_pose_hold") }
    func testS03BusyHandoff() throws { try check("s03_busy_handoff") }
    func testS04StopThenReset() throws { try check("s04_stop_then_reset") }
    func testS05PoseWatchdog() throws { try check("s05_pose_watchdog") }
    func testS06EstopInHold() throws { try check("s06_estop_in_hold") }
    func testS07EstopThenResetScene() throws { try check("s07_estop_then_reset_scene") }
    func testS08GripperJog() throws { try check("s08_gripper_jog") }
    func testS09GripperWatchdog() throws { try check("s09_gripper_watchdog") }
    func testS10OrientHold() throws { try check("s10_orient_hold") }
    func testS11ButtonsStepFails() throws { try check("s11_buttons_step_fails") }
    func testS12Invalid() throws { try check("s12_invalid") }
    func testS13WorkspaceEdge() throws { try check("s13_workspace_edge") }
    func testS14DisconnectInHold() throws { try check("s14_disconnect_in_hold") }
    func testS15GripperStep() throws { try check("s15_gripper_step") }
    func testS16WristJog() throws { try check("s16_wrist_jog") }
    func testS17JogAxes() throws { try check("s17_jog_axes") }

    func testEveryRecordingIsChecked() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Recordings", withExtension: nil))
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
            .filter { $0.hasSuffix(".jsonl") }.map { String($0.dropLast(".jsonl".count)) }
        XCTAssertEqual(Set(names), Set(Replay.order))
    }

    private func check(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let replay = try Replay.shared.get()
        let window = try XCTUnwrap(replay.windows[name], "\(name) was not replayed")
        let problems = Comparison(window: window, exclusion: Exclusion.all[name] ?? Exclusion()).problems
        for problem in problems { XCTFail("\(name): \(problem)", file: file, line: line) }
    }
}

/// Parts of recordings the model does not reproduce on purpose. Each says what and why.
struct Exclusion {
    /// Compare only up to this time in the scenario.
    var until: Double?
    /// The real server's event loop stalled in these intervals, so what it sent then is logged late: those
    /// messages are not held to the timing rules.
    var stalls: [ClosedRange<Double>] = []

    static let all: [String: Exclusion] = [
        // At 7.1 s the client sends a coarse move down. The real arm's jaws came down on the cube's top face, 2 to 3 cm
        // beside the pinch point, so the move missed its tolerance after 11 s and the server E-stopped (the cube is
        // seen tilting in the recording). The model's only jaw geometry is the pinch point, so it completes that move,
        // and everything after it differs: the next command is no longer refused busy, nothing is refused
        // estop_active. Compared up to 8 s, which includes the `busy` refusal of the second move. That refusal is
        // logged 0.3 s late: the server stalled from 6.8 s (its 200 ms states stop) to 7.4 s.
        "s11_buttons_step_fails": Exclusion(until: 8.0, stalls: [6.81...7.43]),
        // The real server's event loop stalled for about 0.4 s near the end of this hold (the state at 5.975 s carries
        // seq 537 while the client had sent up to 549), so its 200 ms timer fired with updates still queued. A stall
        // is not something to model.
        "s13_workspace_edge": Exclusion(stalls: [5.58...5.98]),
    ]
}

/// The recordings were made in one server run by one script (trace_scenarios.py), in this order, with steps of its
/// own between them that it did not record. Replaying them the same way gives each scenario the history it had on the
/// server: the episode count, the state fields earlier holds added, the step size.
final class Replay {
    static let order = [
        "s00_hello", "s01_idle", "s02_pose_hold", "s03_busy_handoff", "s04_stop_then_reset", "s05_pose_watchdog",
        "s06_estop_in_hold", "s07_estop_then_reset_scene", "s08_gripper_jog", "s09_gripper_watchdog", "s10_orient_hold",
        "s11_buttons_step_fails", "s12_invalid", "s13_workspace_edge", "s14_disconnect_in_hold", "s15_gripper_step",
        "s16_wrist_jog", "s17_jog_axes",
    ]

    private enum Step {
        case open
        case hello(wait: Double)
        /// Back to an idle scene between scenarios: `estop_reset` if the client last saw an E-stop (then 1.5 s),
        /// `reset_scene`, 7 s.
        case settle
        case scenario(String)
        case close
    }

    /// First run: s00 is its greeting, then s01 to s13 on the same socket, then s14 on two sockets of its own.
    /// Second run, later the same day, same server: s15 to s17.
    private static let plan: [Step] = {
        var steps: [Step] = [.open, .scenario("s00_hello")]
        for name in order[1...13] { steps += [.settle, .scenario(name)] }
        steps += [.settle, .close, .open, .hello(wait: 1.0), .settle, .scenario("s14_disconnect_in_hold"), .settle, .close]
        steps += [.open, .hello(wait: 1.5)]
        for name in order[15...] { steps += [.settle, .scenario(name)] }
        return steps
    }()

    static let shared = Result { try Replay() }

    struct Window {
        let recording: Recording
        let start: Double
        let outputs: [ServerOutput]
    }

    let model = ServerModel(config: .s4Simulator)
    private(set) var windows: [String: Window] = [:]
    private var clock = 0.0
    private var socket = 0
    private var lastSeq = 0
    private var lastSentAt = 0.0
    private var estopSeen = false

    private init() throws {
        for step in Self.plan {
            switch step {
            case .open:
                socket = model.open()
                lastSeq = 0
            case .hello(let wait):
                send("hello", .object(["client": "phone", "name": "thomas-app"]))
                pass(wait)
            case .settle:
                if estopSeen {
                    send("estop_reset")
                    pass(1.5)
                }
                send("reset_scene")
                pass(7)
                estopSeen = false
            case .close:
                _ = model.close(socket, at: clock)
            case .scenario(let name):
                try play(Recording.load(name))
            }
        }
    }

    private func send(_ type: String, _ payload: JSONValue = .object([])) {
        lastSeq += 1
        let message = JSONValue.object(["v": 1, "type": .string(type), "ts": 0, "seq": .int(lastSeq), "payload": payload])
        _ = model.receive(message.text, from: socket, at: clock)
    }

    private func pass(_ seconds: Double) {
        clock += seconds
        _ = model.advance(to: clock)
    }

    private func play(_ recording: Recording) {
        let start = clock
        var sockets: Set<Int> = [socket]
        var outputs: [ServerOutput] = []
        for line in recording.lines where line.outgoing {
            guard let seq = line.seq else {
                // s14's note that the script reopened its socket. It had closed the old one straight after its last
                // update: the `async with` block ends when the hold's update loop does, one 1/30 s sleep later.
                outputs += model.close(socket, at: lastSentAt + 1.0 / 30)
                socket = model.open()
                sockets.insert(socket)
                lastSeq = 0
                continue
            }
            outputs += model.receive(line.message.text, from: socket, at: start + line.time)
            // The script's counter: its hand-made bad message (s12, seq 9999) used a number of its own.
            lastSeq = seq
            lastSentAt = start + line.time
        }
        clock = start + recording.duration + 0.1
        outputs += model.advance(to: clock)
        estopSeen = recording.received.last { $0.type == "state" }?.payload["estop"]?.boolValue ?? false
        windows[recording.name] = Window(
            recording: recording, start: start, outputs: outputs.filter { sockets.contains($0.connection) }
        )
    }
}

/// What a client sees of one scenario, recorded or modelled, and how the two differ.
struct Comparison {
    struct Event {
        let time: Double
        let message: JSONValue
        /// A state that came with the ack or welcome just before it, not from the 200 ms timer: the next message,
        /// with the same seq, sent back to back (0 to 10 ms apart in the recordings, against at least 199 ms for a
        /// timer state).
        let follows: Bool

        var type: String { message["type"]?.stringValue ?? "" }
        var payload: JSONValue { message["payload"] ?? .object([]) }
    }

    let problems: [String]

    init(window: Replay.Window, exclusion: Exclusion) {
        let recording = window.recording
        let horizon = exclusion.until ?? recording.duration + 0.001
        let recorded = Self.events(recording.received.filter { $0.time <= horizon }.map { ($0.time, $0.message) })
        let modelled = Self.events(window.outputs.map { ($0.time - window.start, $0.message) }.filter { $0.0 <= horizon })
        let sent = recording.sent.filter { $0.time <= horizon }
        var problems: [String] = []

        func same<T: Equatable>(_ what: String, _ pick: ([Event]) -> T) {
            let real = pick(recorded), model = pick(modelled)
            if real != model { problems.append("\(what): recorded \(real), model \(model)") }
        }
        same("acks (seq, status, reason)") { $0.filter { $0.type == "ack" }.map(Self.ackText) }
        same("state with each ack (seq, estop, ik)", Self.statesWithAcks)
        same("errors (seq, code)") { events in
            events.filter { $0.type == "error" }.map { "\($0.message["seq"]?.intValue ?? 0) \($0.payload["code"]?.stringValue ?? "")" }
        }
        same("test echoes") { $0.filter { $0.type == "test" }.map { $0.message["seq"]?.intValue ?? 0 } }
        same("welcome config") { $0.filter { $0.type == "welcome" }.map { $0.payload["config"] ?? .null } }
        problems += Self.ackTiming(recorded, modelled, sent: sent, exclusion: exclusion)

        // No unprompted state while the client keeps sending. Recorded times carry up to tens of milliseconds of
        // network delay, so a state the server sent just before a stretch began may be logged just after it.
        for stretch in Self.stretches(sent.map(\.time)) {
            for (who, events) in [("recorded", recorded), ("model", modelled)] {
                let stray = events.filter { event in
                    event.type == "state" && !event.follows && event.time > stretch.lowerBound + 0.05
                        && event.time <= stretch.upperBound
                        && !(who == "recorded" && exclusion.stalls.contains { $0.contains(event.time) })
                }
                for state in stray {
                    problems.append("\(who) state at \(state.time) while the client sent every 200 ms (\(stretch))")
                }
            }
        }
        // In each silence, a state every 200 ms.
        let times = sent.map(\.time) + [horizon]
        for (from, to) in zip(times, times.dropFirst()) where to - from > 0.3 {
            let real = Self.unprompted(recorded, from, to), model = Self.unprompted(modelled, from, to)
            let allowed = 1 + Int(0.02 * Double(real))
            if (real > 0 && model == 0) || abs(real - model) > allowed {
                problems.append("states in the silence \(from)...\(to): recorded \(real), model \(model)")
            }
        }

        let realStates = recorded.filter { $0.type == "state" }, modelStates = modelled.filter { $0.type == "state" }
        if realStates.isEmpty != modelStates.isEmpty {
            problems.append("states: recorded \(realStates.count), model \(modelStates.count)")
        }
        if let firstReal = realStates.first, let lastReal = realStates.last,
           let firstModel = modelStates.first, let lastModel = modelStates.last {
            for (which, real, model) in [("first", firstReal, firstModel), ("last", lastReal, lastModel)] {
                let a = Self.signature(real.payload), b = Self.signature(model.payload)
                if a != b { problems.append("\(which) state fields: recorded \(a), model \(b)") }
            }
            for key in ["estop", "ik", "episode", "gripper", "step", "task_success", "rec", "rec_saved", "rec_discarded", "rec_samples"] {
                let real = lastReal.payload[key], model = lastModel.payload[key]
                if real != model { problems.append("final \(key): recorded \(Self.text(real)), model \(Self.text(model))") }
            }
            problems += Self.loose(lastReal.payload, lastModel.payload, start: window)
        }
        self.problems = problems
    }

    private static let oneShots: Set<String> = ["move_delta", "joint_delta", "gripper", "reset_scene"]
    private static let startsAndOneShots = oneShots.union(["jog_start", "joint_jog_start", "gripper_jog_start", "orient_start", "pose_start"])

    private static func ackTiming(_ recorded: [Event], _ modelled: [Event], sent: [Recording.Line], exclusion: Exclusion) -> [String] {
        var problems: [String] = []
        for real in recorded where real.type == "ack" && !exclusion.stalls.contains(where: { $0.contains(real.time) }) {
            let seq = real.payload["seq"]?.intValue
            guard let model = modelled.first(where: { $0.type == "ack" && $0.payload["seq"]?.intValue == seq }),
                  let request = sent.first(where: { $0.seq == seq }) else { continue }
            let reason = real.payload["reason"]?.stringValue ?? ""
            let atOnce = !startsAndOneShots.contains(request.type) || ["busy", "estop_active", "sim_not_ready"].contains(reason)
                || reason.hasPrefix("invalid_") || reason.hasSuffix("_not_supported")
            let tolerance: Double
            if atOnce {
                tolerance = 0.05
            } else if oneShots.contains(request.type) {
                tolerance = 0.2 * (real.time - request.time)
            } else {
                tolerance = 0.1
            }
            if abs(model.time - real.time) > tolerance {
                problems.append(String(format: "ack %d %@ at %.3f s, recorded at %.3f s", seq ?? -1, reason, model.time, real.time))
            }
        }
        return problems
    }

    private static func events(_ list: [(Double, JSONValue)]) -> [Event] {
        var previous: (time: Double, message: JSONValue)?
        return list.map { time, message in
            defer { previous = (time, message) }
            guard message["type"] == "state", let previous, ["ack", "welcome"].contains(previous.message["type"]?.stringValue),
                  previous.message["seq"] == message["seq"], time - previous.time <= 0.02 else {
                return Event(time: time, message: message, follows: false)
            }
            return Event(time: time, message: message, follows: true)
        }
    }

    /// For each ack in order: whether a state came with it and, if so, that state's `estop` and `ik`. The server
    /// sends one after every accepted command and every final ack, and none after a refusal such as `busy`.
    private static func statesWithAcks(_ events: [Event]) -> [String] {
        zip(events, events.dropFirst().map(Optional.some) + [nil]).compactMap { event, next in
            guard event.type == "ack" else { return nil }
            let seq = event.message["seq"]?.intValue ?? -1
            guard let next, next.follows else { return "\(seq) no state" }
            return "\(seq) estop \(text(next.payload["estop"])) ik \(text(next.payload["ik"]))"
        }
    }

    private static func ackText(_ event: Event) -> String {
        let payload = event.payload
        return "\(payload["seq"]?.intValue ?? -1) \(payload["status"]?.stringValue ?? "") \(payload["reason"]?.stringValue ?? "")"
    }

    /// Runs of client messages less than 200 ms apart, from the first to the last.
    private static func stretches(_ times: [Double]) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        var first: Double?
        for (time, next) in zip(times, times.dropFirst() + [Double.infinity]) {
            if first == nil { first = time }
            if next - time >= 0.2 {
                if let begin = first, time > begin { result.append(begin...time) }
                first = nil
            }
        }
        return result
    }

    private static func unprompted(_ events: [Event], _ from: Double, _ to: Double) -> Int {
        events.filter { $0.type == "state" && !$0.follows && $0.time > from && $0.time < to }.count
    }

    /// Keys and JSON types of a state, sorted.
    static func signature(_ payload: JSONValue) -> [String] {
        (payload.members ?? []).map { member in
            let kind: String
            switch member.value {
            case .null: kind = "null"
            case .bool: kind = "bool"
            case .int, .double: kind = "number"
            case .string: kind = "string"
            case .array(let values): kind = "array\(values.count)"
            case .object: kind = "object"
            }
            return "\(member.key):\(kind)"
        }.sorted()
    }

    private static func text(_ value: JSONValue?) -> String { value?.text ?? "missing" }

    private static func loose(_ real: JSONValue, _ model: JSONValue, start window: Replay.Window) -> [String] {
        var problems: [String] = []
        for key in ["wrist_flex_deg", "wrist_roll_deg", "gripper_deg"] {
            guard let a = real[key]?.numberValue, let b = model[key]?.numberValue else { continue }
            if abs(a - b) > 5 { problems.append("final \(key): recorded \(a), model \(b)") }
        }
        let armStart = ServerModelConfig.s4Simulator.armStart
        if let a = vector(real["ee_pos"]), let b = vector(model["ee_pos"]) {
            let realMove = a - armStart, modelMove = b - armStart
            if length(realMove) > 0.01 {
                let cosine = (realMove * modelMove).sum() / (length(realMove) * max(length(modelMove), 1e-9))
                if cosine < cos(Double.pi / 4) {
                    problems.append("arm moved \(realMove) on the server and \(modelMove) in the model")
                }
            }
        }
        if let a = vector(real["object_pos"]), let b = vector(model["object_pos"]), length(a - b) > 0.01 {
            problems.append("final cube: recorded \(a), model \(b)")
        }
        return problems
    }

    private static func vector(_ value: JSONValue?) -> SIMD3<Double>? {
        guard let numbers = value?.arrayValue?.compactMap(\.numberValue), numbers.count == 3 else { return nil }
        return SIMD3(numbers[0], numbers[1], numbers[2])
    }
}
