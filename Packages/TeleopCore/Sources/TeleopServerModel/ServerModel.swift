import Foundation

/// One message the server sends.
public struct ServerOutput: Equatable, Sendable {
    public let connection: Int
    /// Model time it is sent at, seconds.
    public let time: Double
    public let message: JSONValue
    /// The text on the wire. For an echoed `test` it is the client's own text, byte for byte.
    public let text: String

    public var type: String { message["type"]?.stringValue ?? "" }
    public var payload: JSONValue { message["payload"] ?? .object([]) }
}

/// A deterministic model of the S4 simulator server: the rules of its WebSocket front end and of its simulation
/// loop, over the small `World`. Time is passed in, in seconds, and never read from a clock.
///
/// `receive` and `close` first run everything due up to their time, then handle the event. Each returns, in
/// order, what the server sends in that time. Several connections can be open at once, as on the real server.
public final class ServerModel {
    public let config: ServerModelConfig
    /// The model's clock, seconds.
    public private(set) var time: Double
    public internal(set) var world: World
    /// What `state` says now.
    public internal(set) var state: JSONValue = .object([])
    public internal(set) var episode = 0

    var connections: [Int: Connection] = [:]
    private var nextConnection = 1
    var outbox: [ServerOutput] = []
    /// Final acks not yet sent. On the server, finishing a command only resolves a future; the socket side writes
    /// the ack and a state once the loop's pass, or the front end's own reply, is done. So that state already
    /// shows what the rest of the pass did (an E-stop the failure engaged), and an E-stop's own ack goes out
    /// before the rejection of a start it caught in the queue.
    private var completions: [(seq: Int, owner: Int, status: String, reason: String)] = []
    /// When the loop's next pass runs.
    private var nextStepTime: Double

    // The front end's shared state (the server's `Bridge`).
    /// The one command queued or running. A new one is `busy` until it has finished.
    var pending: Command?
    var estop = false
    /// The loop has held the arm for at least one step since the E-stop; only then may it be reset.
    var estopFrozen = false
    /// Held starts whose stop has been asked for. An E-stop asks for all of them.
    var stopRequested: Set<String> = []
    /// False while the scene resets and while a success is shown: starts are refused `sim_not_ready`.
    var ready = true

    // The simulation loop.
    var active: Command?
    var recorder: Recorder?
    var successRun = 0
    var successLatched = false
    var successDisplayLeft = 0
    var reset: Reset?

    struct Reset {
        var stepsLeft: Int
        var command: Command?
    }

    public init(config: ServerModelConfig = .s4Simulator, startTime: Double = 0) {
        self.config = config
        time = startTime
        nextStepTime = startTime + 1 / config.stepsPerSecond
        world = World(config)
        recorder = config.recorder.map(Recorder.init)
        recorder?.arm()
        update([
            "ee_pos": .numbers(world.arm), "gripper": "closed", "step": "coarse", "ik": "ok", "estop": .bool(false),
            "object_pos": .numbers(world.cube), "goal_pos": .numbers(config.goalWorld),
            "task_success": .bool(false), "episode": .int(0),
        ])
        publishMeasured()
    }

    // MARK: Public API

    /// A new client socket. Nothing is sent until it says `hello`.
    public func open() -> Int {
        let id = nextConnection
        nextConnection += 1
        connections[id] = Connection(stateInterval: config.stateInterval)
        return id
    }

    /// The client's socket closed at `time`. If it owned the running command, the server E-stops.
    public func close(_ id: Int, at time: Double) -> [ServerOutput] {
        run(until: time, frameArrives: true)
        guard let connection = connections[id], connection.isOpen else { return drain() }
        connection.isOpen = false
        connection.quietSince = nil
        if let command = pending, command.owner == id, !command.finished { engageEstop() }
        sendCompletions()
        return drain()
    }

    /// One text frame from the client.
    public func receive(_ text: String, from id: Int, at time: Double) -> [ServerOutput] {
        run(until: time, frameArrives: true)
        guard let connection = connections[id], connection.isOpen else { return drain() }
        handle(text, connection, id)
        sendCompletions()
        // The server waits for the next frame afresh after each one: state goes out only after this much silence.
        connection.quietSince = self.time
        connection.statesSinceQuiet = 0
        return drain()
    }

    /// Runs the simulation and the state timers up to `time`.
    public func advance(to time: Double) -> [ServerOutput] {
        run(until: time)
        return drain()
    }

    /// When the model next does something by itself: a simulation step or a state broadcast.
    public var nextEventTime: Double {
        min(nextStepTime, nextTimer)
    }

    /// Open sockets whose client has said hello.
    public var welcomedClients: Int { connections.values.filter { $0.isOpen && $0.welcomed }.count }

    // MARK: Time

    /// A pass is one physics step plus the loop's sleep of one simulated step. A reset runs its steps back to back
    /// with no sleep, which is why the real one takes 1.7 s for 45 steps where the loop manages 17 a second.
    private var passInterval: Double {
        let interval = 1 / config.stepsPerSecond
        return reset == nil ? interval : max(interval - config.simStep, interval / 4)
    }

    /// Runs everything due up to `target`. When a frame arrives at that very moment, a state timer due then
    /// loses to it: the frame restarts the wait.
    private func run(until target: Double, frameArrives: Bool = false) {
        while true {
            let step = nextStepTime
            let timer = nextTimer
            guard min(step, timer) <= target else { break }
            if step <= timer {
                time = max(time, step)
                loopPass()
                sendCompletions()
                nextStepTime = time + passInterval
            } else {
                if frameArrives, timer > target - 1e-9 { break }
                time = max(time, timer)
                for (id, connection) in connections.sorted(by: { $0.key < $1.key })
                where connection.nextStateAt == timer {
                    if connection.welcomed { sendState(seq: connection.highestSeq, to: id) }
                    connection.statesSinceQuiet += 1
                }
            }
        }
        time = max(time, target)
    }

    private var nextTimer: Double { connections.values.compactMap(\.nextStateAt).min() ?? .infinity }

    private func drain() -> [ServerOutput] {
        defer { outbox = [] }
        return outbox
    }

    // MARK: Sending

    func send(_ type: String, seq: Int, _ payload: JSONValue, to id: Int) {
        guard let connection = connections[id], connection.isOpen else { return }
        let message = JSONValue.object([
            "v": .int(connection.version ?? 0), "type": .string(type),
            "ts": .int(config.clockOriginMs + Int((time * 1000).rounded(.down))), "seq": .int(seq), "payload": payload,
        ])
        outbox.append(ServerOutput(connection: id, time: time, message: message, text: message.text))
    }

    func ack(_ seq: Int, _ status: String, _ reason: String, to id: Int) {
        send(
            "ack", seq: seq, .object(["seq": .int(seq), "status": .string(status), "reason": .string(reason)]), to: id)
    }

    func sendState(seq: Int, to id: Int) { send("state", seq: seq, state, to: id) }

    private func error(_ code: String, _ msg: String, seq: Int, to id: Int) {
        send("error", seq: seq, .object(["code": .string(code), "msg": .string(msg)]), to: id)
    }

    func update(_ fields: KeyValuePairs<String, JSONValue>) {
        for (key, value) in fields { state = state.setting(key, value) }
        // Every `ee_pos` is the world's arm, so the pinch point goes with it.
        if config.reportsToolPoint, fields.contains(where: { $0.key == "ee_pos" }) {
            state = state.setting("tool_pos", .numbers(world.pinch(config)))
        }
    }

    // MARK: Front end

    private func handle(_ text: String, _ connection: Connection, _ id: Int) {
        guard let message = JSONValue.parse(text) else {
            error("invalid_json", "unable to parse JSON", seq: -1, to: id)
            return
        }
        if let (seq, code, msg) = Validation.envelope(message) {
            error(code, msg, seq: seq, to: id)
            return
        }
        let version = message["v"]!.intValue!
        if connection.version == nil {
            connection.version = version
        } else if version != connection.version {
            error(
                "version_changed", "protocol version must remain constant per connection",
                seq: message["seq"]!.intValue!, to: id)
            return
        }
        let seq = message["seq"]!.intValue!
        // A repeated or older seq is dropped without a word.
        guard seq > connection.highestSeq else { return }
        connection.highestSeq = seq
        let kind = message["type"]!.stringValue!
        let payload = message["payload"]!

        if kind == "hello" {
            guard payload.keys == ["client", "name"] else {
                error("invalid_hello", "payload must contain client and name", seq: seq, to: id)
                return
            }
            guard payload["client"]?.stringValue == "phone", payload["name"]?.stringValue != nil else {
                error("invalid_hello", "client must be phone and name must be a string", seq: seq, to: id)
                return
            }
            connection.welcomed = true
            send(
                "welcome", seq: seq,
                .object([
                    "session": .string(config.session),
                    "config": .object([
                        "coarse_cm": .double(config.coarseCentimetres), "fine_cm": .double(config.fineCentimetres),
                    ]),
                ]), to: id)
            sendState(seq: seq, to: id)
            return
        }
        guard connection.welcomed else {
            error("hello_required", "send hello before commands", seq: seq, to: id)
            return
        }

        switch kind {
        case "test":
            outbox.append(ServerOutput(connection: id, time: time, message: message, text: text))
        case "estop", "estop_reset":
            guard payload.keys == [] else {
                ack(seq, "rejected", "invalid_\(kind)", to: id)
                return
            }
            let (status, reason) = kind == "estop" ? engageEstopFromClient() : resetEstop()
            ack(seq, status, reason, to: id)
            sendState(seq: seq, to: id)
        case "jog_keepalive", "jog_stop", "joint_jog_stop", "gripper_jog_stop", "orient_stop", "pose_stop":
            guard payload.keys == [] else {
                ack(seq, "rejected", "invalid_\(kind)", to: id)
                return
            }
            guard !estop else {
                ack(seq, "rejected", "estop_active", to: id)
                return
            }
            if kind == "jog_keepalive" {
                refreshHold(owner: id)
                return
            }
            let (status, reason) = requestStop(kind, owner: id)
            ack(seq, status, reason, to: id)
            sendState(seq: seq, to: id)
        case "orient_update":
            if let (code, msg) = Validation.orientUpdate(payload) {
                error(code, msg, seq: seq, to: id)
                return
            }
            // The newest target and the keepalive in one; deliberately never acked.
            if let command = ownedHold("orient_start", owner: id) {
                command.qRel = Validation.numbers(payload["q_rel"])
                command.deadline = time + config.holdWatchdog
            }
        case "pose_update":
            if let (code, msg) = Validation.poseUpdate(payload) {
                error(code, msg, seq: seq, to: id)
                return
            }
            if let command = ownedHold("pose_start", owner: id) {
                let p = Validation.numbers(payload["p_rel_m"])
                command.pRel = SIMD3(p[0], p[1], p[2])
                command.qRel = Validation.numbers(payload["q_rel"])
                command.gripperDelta = payload["gripper_delta"]?.numberValue ?? 0
                command.deadline = time + config.holdWatchdog
            }
        case "mode":
            if Validation.mode(payload) != nil {
                ack(seq, "rejected", "invalid_mode", to: id)
                return
            }
            update(["step": payload["step"]!])
            ack(seq, "ok", "mode_updated", to: id)
            sendState(seq: seq, to: id)
        default:
            queue(kind, payload: payload, seq: seq, owner: id)
        }
    }

    /// Starts and one-shot commands: the busy rule.
    private func queue(_ kind: String, payload: JSONValue, seq: Int, owner id: Int) {
        if kind == "reset_scene" {
            guard payload.keys == [] else {
                ack(seq, "rejected", "invalid_reset_scene", to: id)
                return
            }
            // A reset clears the E-stop before it is checked against the running command, so even a reset that
            // is then refused `busy` has cleared it. It leaves the stops alone: a stop waiting to land still lands.
            estop = false
            estopFrozen = false
            update(["estop": .bool(false), "ik": "resetting"])
        }
        guard !estop else {
            ack(seq, "rejected", "estop_active", to: id)
            return
        }
        if let code = Validation.command(kind, payload) {
            ack(seq, "rejected", code, to: id)
            return
        }
        guard ready else {
            ack(seq, "rejected", "sim_not_ready", to: id)
            return
        }
        if let running = pending, !running.finished {
            ack(seq, "rejected", "busy", to: id)
            return
        }
        let isHold = Command.holdKinds.contains(kind)
        let command = Command(
            kind: kind, payload: payload, seq: seq, owner: id,
            deadline: time + (isHold ? config.holdWatchdog : config.commandDeadline)
        )
        stopRequested.remove(kind)
        pending = command
    }

    private func ownedHold(_ kind: String, owner id: Int) -> Command? {
        guard let command = pending, command.owner == id, command.kind == kind, !command.finished else { return nil }
        return command
    }

    /// `jog_keepalive` refreshes jog, joint jog and gripper jog holds only; never a pose or orient hold.
    private func refreshHold(owner id: Int) {
        guard let command = pending, command.owner == id, !command.finished,
            ["jog_start", "joint_jog_start", "gripper_jog_start"].contains(command.kind)
        else { return }
        command.deadline = time + config.holdWatchdog
    }

    private func requestStop(_ kind: String, owner id: Int) -> (String, String) {
        let name = String(kind.dropLast("_stop".count))
        guard let command = ownedHold(name + "_start", owner: id) else { return ("rejected", "\(name)_not_active") }
        stopRequested.insert(command.kind)
        command.deadline = time + config.holdWatchdog
        return ("ok", "\(name)_stop_requested")
    }

    private func engageEstopFromClient() -> (String, String) {
        engageEstop()
        return ("ok", "estop_engaged")
    }

    /// Stops everything: every held control is asked to stop, and a command not yet taken by the loop is refused.
    func engageEstop() {
        estopFrozen = false
        estop = true
        stopRequested = Command.holdKinds
        update(["estop": .bool(true), "ik": "stopped"])
        if let queued = pending, !queued.taken, !queued.finished { finish(queued, "rejected", "estop") }
    }

    private func resetEstop() -> (String, String) {
        guard estop else { return ("rejected", "estop_not_active") }
        guard estopFrozen else { return ("rejected", "estop_not_frozen") }
        estop = false
        estopFrozen = false
        update(["estop": .bool(false), "ik": "ok"])
        return ("ok", "estop_reset")
    }

    /// Ends the command. Its one final ack, then a state, go to the connection that sent it at the next
    /// `sendCompletions`.
    func finish(_ command: Command, _ status: String, _ reason: String) {
        if !command.finished {
            command.finished = true
            completions.append((command.seq, command.owner, status, reason))
        }
        if pending === command { pending = nil }
    }

    private func sendCompletions() {
        for completion in completions {
            ack(completion.seq, completion.status, completion.reason, to: completion.owner)
            sendState(seq: completion.seq, to: completion.owner)
        }
        completions = []
    }
}

final class Connection {
    var version: Int?
    var welcomed = false
    var highestSeq = -1
    /// Time of the last frame from this client, and how many unprompted states went out since.
    var quietSince: Double?
    var statesSinceQuiet = 0
    var isOpen = true
    let stateInterval: Double

    init(stateInterval: Double) {
        self.stateInterval = stateInterval
    }

    /// When this connection gets its next unprompted `state`. Nil until its first frame.
    var nextStateAt: Double? { quietSince.map { $0 + Double(statesSinceQuiet + 1) * stateInterval } }
}

/// A start or one-shot command, from the moment it is queued until its final ack.
final class Command {
    static let holdKinds: Set<String> = [
        "jog_start", "joint_jog_start", "gripper_jog_start", "orient_start", "pose_start",
    ]
    /// The commands whose running starts a recorder take.
    static let recordedKinds: Set<String> = holdKinds.union(["move_delta", "joint_delta", "gripper"])

    let kind: String
    let payload: JSONValue
    let seq: Int
    let owner: Int
    var deadline: Double
    var finished = false
    /// The loop has taken it off the queue.
    var taken = false

    // Newest phone input, for pose and orient holds.
    var pRel = SIMD3<Double>.zero
    var qRel: [Double] = [0, 0, 0, 1]
    var gripperDelta = 0.0
    /// The input the loop last used: what a stop reports.
    var usedQ: [Double] = [0, 0, 0, 1]
    var usedGripperDelta = 0.0

    // Running state, set when the loop takes the command.
    var motionStep = 0
    var stableCount = 0
    var contactCount = 0
    var stalled = false
    var wasClamped = false
    var completion = "ok"
    var speed = 0.0
    var rampSteps = 0
    var tolerance = 0.0
    var startPoint = SIMD3<Double>.zero
    var goalPoint = SIMD3<Double>.zero
    var startAngle = 0.0
    var goalAngle = 0.0
    var startFlex = 0.0
    var startRoll = 0.0

    init(kind: String, payload: JSONValue, seq: Int, owner: Int, deadline: Double) {
        self.kind = kind
        self.payload = payload
        self.seq = seq
        self.owner = owner
        self.deadline = deadline
    }

    var step: String { payload["step"]?.stringValue ?? "" }
    var action: String { payload["action"]?.stringValue ?? "" }
    var joint: String { payload["joint"]?.stringValue ?? "" }
    var direction: Double { Double(payload["dir"]?.intValue ?? 0) }
    var axis: Int { ["x": 0, "y": 1, "z": 2][payload["axis"]?.stringValue ?? ""] ?? 0 }
}

extension JSONValue {
    static func numbers(_ vector: SIMD3<Double>) -> JSONValue { .numbers([vector.x, vector.y, vector.z]) }
}
