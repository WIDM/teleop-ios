import Foundation

/// What the server told us, reduced to what the app acts on.
public enum LinkEvent: Equatable, Sendable {
    /// First `state` after `welcome`: the link is usable.
    case up(estop: Bool, gripper: GripperState?)
    case state(estop: Bool, gripper: GripperState?)
    /// The server refused a message. Log only: a refusal of the current hold arrives as `holdRefused`.
    case rejected(type: String, reason: String)
    /// The server refused or ended the hold that is active now.
    case holdRefused(reason: String)
    /// The server finished the hold that `poseStop` ended; a new one can start.
    case holdStopped
    /// The server refused or ended the gripper jog that is running now.
    case gripperRefused(reason: String)
    /// The server refused or ended the jaw turn that is running now.
    case turnRefused(reason: String)
    case latency(ms: Int)
}

public struct PoseParams: Equatable, Sendable {
    public var gain: Double
    public var deadbandDegrees: Double
    public var smoothing: Double

    public init(gain: Double, deadbandDegrees: Double, smoothing: Double) {
        // Ranges the server accepts; outside them it rejects pose_start.
        self.gain = min(max(gain, 0.1), 2.0)
        self.deadbandDegrees = min(max(deadbandDegrees, 0), 15)
        self.smoothing = min(max(smoothing, 0), 0.95)
    }
}

/// One WebSocket conversation with the teleop server (hold protocol, envelope v1).
/// No sockets or timers here: the owner passes outgoing text to `send` and feeds incoming text to `receive`.
/// Not thread safe; use from one queue.
public final class TeleopLink {
    public static let protocolVersion = 1
    public static let poseRateHz = 30
    /// This long without any message means the link is dead. The server is quiet during a hold
    /// (it only broadcasts state when idle), so the owner must keep probing at least twice in this time.
    public static let staleAfterMs = 2000

    private let send: (String) -> Void
    private let now: () -> Int
    private var seq = 0
    private var welcomed = false
    private var sentTypes: [Int: String] = [:]
    private var probes: [Int: Int] = [:]
    private var lastHeardAt: Int?
    private var holdSeq: Int?
    /// The hold `poseStop` just ended, until the server confirms it has finished.
    private var stoppingSeq: Int?

    /// Arm tip position from the newest `state`, in metres. The server sends none during a hold.
    public private(set) var lastEndEffector: [Double]?
    /// Task object and goal positions from the newest `state`, in metres in the robot base frame.
    public private(set) var lastObject: [Double]?
    public private(set) var lastGoal: [Double]?
    /// Gripper as the newest `state` named it.
    public private(set) var lastGripper: GripperState?
    /// True after `welcome` and a first `state`.
    public private(set) var ready = false
    /// True between an accepted `poseStart` and the stop that ends it.
    public private(set) var holdActive = false
    /// True while a gripper jog is running. The server stops it 750 ms after the last `keepalive`.
    public private(set) var gripperJogActive = false
    private var gripperJogSeq: Int?
    /// True between an `orientStart` and the stop or refusal that ends it. The server drops it 750 ms after the last update.
    public private(set) var turnActive = false
    private var turnSeq: Int?

    /// - Parameters:
    ///   - send: writes one text frame.
    ///   - now: clock in milliseconds.
    public init(send: @escaping (String) -> Void, now: @escaping () -> Int) {
        self.send = send
        self.now = now
    }

    public func hello() {
        emit("hello", ["client": "phone", "name": "thomas-app"])
    }

    /// Starts a hold. Returns false, sending nothing, if the link is not ready or a hold is already active.
    @discardableResult
    public func poseStart(_ params: PoseParams) -> Bool {
        guard ready, !holdActive else { return false }
        // The server runs one held control at a time.
        gripperJogStop()
        orientStop()
        holdActive = true
        holdSeq = emit("pose_start", [
            "frame": "webxr_local",
            "rate_hz": Self.poseRateHz,
            "control_mode": "translation",
            "gain": params.gain,
            "deadband_deg": params.deadbandDegrees,
            "smoothing": params.smoothing,
        ])
        return true
    }

    /// Phone position relative to the start of the hold, in metres. Ignored outside a hold.
    public func poseUpdate(positionMeters p: [Double]) {
        guard holdActive, p.count == 3, p.allSatisfy(\.isFinite) else { return }
        emit("pose_update", [
            "p_rel_m": p.map { ($0 * 10000).rounded() / 10000 },
            // Translation mode: the server ignores rotation, so send none.
            "q_rel": [0, 0, 0, 1],
            "gripper_delta": 0,
        ])
    }

    /// Ends the hold. Safe to call when none is active.
    public func poseStop() {
        guard holdActive else { return }
        holdActive = false
        stoppingSeq = holdSeq
        holdSeq = nil
        emit("pose_stop", [:])
    }

    public func estop() {
        holdActive = false
        holdSeq = nil
        gripperJogActive = false
        gripperJogSeq = nil
        turnActive = false
        turnSeq = nil
        emit("estop", [:])
    }

    public func estopReset() { emit("estop_reset", [:]) }

    public func resetScene() {
        poseStop()
        gripperJogStop()
        orientStop()
        emit("reset_scene", [:])
    }

    /// Starts moving the gripper toward `target`, replacing any jog already running.
    /// The server's one-shot `gripper` message blocks every other command for tens of seconds in simulation,
    /// so the jog messages are used instead. The jog never ends by itself: on contact the server only stops
    /// squeezing harder. The owner sends `keepalive` and decides when to call `gripperJogStop`.
    public func gripperJogStart(_ target: GripperState) {
        guard ready, !holdActive else { return }
        orientStop()
        gripperJogStop()
        gripperJogActive = true
        gripperJogSeq = emit("gripper_jog_start", ["action": target == .open ? "open" : "close", "step": "coarse"])
    }

    /// Must go out at least every 750 ms while a gripper jog runs; the server expects every 150 ms.
    public func keepalive() {
        guard gripperJogActive else { return }
        emit("jog_keepalive", [:])
    }

    public func gripperJogStop() {
        guard gripperJogActive else { return }
        gripperJogActive = false
        gripperJogSeq = nil
        emit("gripper_jog_stop", [:])
    }

    /// Starts turning the jaws, replacing any turn already running. The server rolls the wrist by the rotation
    /// about y that `orientUpdate` asks for, at most 60 degrees from where the wrist was when this hold began.
    /// Returns false, sending nothing, if the link is not ready or an arm hold is active.
    @discardableResult
    public func orientStart() -> Bool {
        guard ready, !holdActive else { return false }
        // The server runs one held control at a time.
        gripperJogStop()
        orientStop()
        turnActive = true
        turnSeq = emit("orient_start", [
            "frame": "phone_body",
            "rate_hz": Self.poseRateHz,
            "gain": 1.0,
            "deadband_deg": 0.0,
            "smoothing": 0.0,
        ])
        return true
    }

    /// Roll asked for, in degrees from the wrist as it was when the hold began. Positive turns the same way
    /// as the server's wrist roll increases. Also the keepalive: the server drops the hold 750 ms after the last one.
    public func orientUpdate(rollDegrees: Double) {
        guard turnActive, rollDegrees.isFinite else { return }
        // The server reads the rotation about y, negated, as the wrist roll. x and z stay 0: x would pitch the wrist.
        let half = rollDegrees * .pi / 360
        // Adding 0 turns a negative zero into 0, so a roll of 0 sends [0, 0, 0, 1].
        let y = (-sin(half) * 1_000_000).rounded() / 1_000_000 + 0
        let w = (cos(half) * 1_000_000).rounded() / 1_000_000
        emit("orient_update", ["q_rel": [0, y, 0, w]])
    }

    /// Ends the turn; the joint stays where it is. Safe to call when none is active.
    public func orientStop() {
        guard turnActive else { return }
        turnActive = false
        turnSeq = nil
        emit("orient_stop", [:])
    }

    /// Asks the server to echo one message, to time the round trip.
    public func probe() {
        guard ready else { return }
        probes[emit("test", [:])] = now()
        // An unanswered probe must not pile up.
        if probes.count > 8, let oldest = probes.keys.min() { probes[oldest] = nil }
    }

    /// Forget unanswered probes. After the app was suspended their echoes would read as seconds of latency.
    public func dropProbes() {
        probes = [:]
        if ready { lastHeardAt = now() }
    }

    /// True when the link was ready but the server has been silent too long.
    public var isStale: Bool {
        guard ready, let lastHeardAt else { return false }
        return now() - lastHeardAt > Self.staleAfterMs
    }

    /// The socket is gone: nothing is held and nothing more is sent on it.
    public func transportClosed() {
        ready = false
        welcomed = false
        holdActive = false
        holdSeq = nil
        stoppingSeq = nil
        gripperJogActive = false
        gripperJogSeq = nil
        turnActive = false
        turnSeq = nil
        probes = [:]
        sentTypes = [:]
        lastHeardAt = nil
    }

    public func receive(_ text: String) -> LinkEvent? {
        guard let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = message["type"] as? String else { return nil }
        let payload = message["payload"] as? [String: Any] ?? [:]
        if welcomed { lastHeardAt = now() }
        switch type {
        case "welcome":
            welcomed = true
            lastHeardAt = now()
            return nil
        case "state":
            guard welcomed else { return nil }
            if let position = payload["ee_pos"] as? [Double], position.count == 3 { lastEndEffector = position }
            if let position = payload["object_pos"] as? [Double], position.count == 3 { lastObject = position }
            if let position = payload["goal_pos"] as? [Double], position.count == 3 { lastGoal = position }
            if let name = payload["gripper"] as? String, let parsed = Self.gripperState(name) { lastGripper = parsed }
            let estop = payload["estop"] as? Bool ?? false
            let gripper = (payload["gripper"] as? String).flatMap(Self.gripperState)
            if !ready {
                ready = true
                return .up(estop: estop, gripper: gripper)
            }
            return .state(estop: estop, gripper: gripper)
        case "test":
            guard let seq = message["seq"] as? Int, let sent = probes.removeValue(forKey: seq) else { return nil }
            return .latency(ms: max(0, now() - sent))
        case "ack":
            guard let seq = payload["seq"] as? Int, let sentType = sentTypes.removeValue(forKey: seq) else { return nil }
            let finishedStop = seq == stoppingSeq
            if finishedStop { stoppingSeq = nil }
            guard payload["status"] as? String == "rejected" else { return finishedStop ? .holdStopped : nil }
            let reason = payload["reason"] as? String ?? ""
            // Only the current hold's refusal ends it. A late refusal of an earlier press must not cancel this one.
            if sentType == "pose_start", seq == holdSeq {
                holdActive = false
                holdSeq = nil
                return .holdRefused(reason: reason)
            }
            // Same rule for the gripper: only the running jog's refusal (busy, watchdog) ends it.
            if sentType == "gripper_jog_start", seq == gripperJogSeq {
                gripperJogActive = false
                gripperJogSeq = nil
                return .gripperRefused(reason: reason)
            }
            if sentType == "orient_start", seq == turnSeq {
                turnActive = false
                turnSeq = nil
                return .turnRefused(reason: reason)
            }
            return .rejected(type: sentType, reason: reason)
        default:
            return nil
        }
    }

    private static func gripperState(_ text: String) -> GripperState? {
        switch text {
        case "open": return .open
        // The server starts with "closed" and says "close" after a closing command.
        case "closed", "close": return .closed
        default: return nil
        }
    }

    @discardableResult
    private func emit(_ type: String, _ payload: [String: Any]) -> Int {
        seq += 1
        let message: [String: Any] = [
            "v": Self.protocolVersion, "type": type, "ts": now(), "seq": seq, "payload": payload,
        ]
        // pose_update, orient_update and test get no ack; remembering them would only grow the table.
        if type != "pose_update", type != "orient_update", type != "test", type != "jog_keepalive" { sentTypes[seq] = type }
        if sentTypes.count > 64, let oldest = sentTypes.keys.min() { sentTypes[oldest] = nil }
        if let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            send(text)
        }
        return seq
    }
}
