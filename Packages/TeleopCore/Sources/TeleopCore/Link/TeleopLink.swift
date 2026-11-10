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

    /// True after `welcome` and a first `state`.
    public private(set) var ready = false
    /// True between an accepted `poseStart` and the stop that ends it.
    public private(set) var holdActive = false

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
        holdSeq = nil
        emit("pose_stop", [:])
    }

    public func estop() {
        holdActive = false
        holdSeq = nil
        emit("estop", [:])
    }

    public func estopReset() { emit("estop_reset", [:]) }

    public func resetScene() {
        poseStop()
        emit("reset_scene", [:])
    }

    public func gripper(_ target: GripperState) {
        emit("gripper", ["action": target == .open ? "open" : "close"])
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
            guard payload["status"] as? String == "rejected" else { return nil }
            let reason = payload["reason"] as? String ?? ""
            // Only the current hold's refusal ends it. A late refusal of an earlier press must not cancel this one.
            if sentType == "pose_start", seq == holdSeq {
                holdActive = false
                holdSeq = nil
                return .holdRefused(reason: reason)
            }
            return .rejected(type: sentType, reason: reason)
        default:
            return nil
        }
    }

    private static func gripperState(_ text: String) -> GripperState? {
        switch text {
        case "open": return .open
        case "closed": return .closed
        default: return nil
        }
    }

    @discardableResult
    private func emit(_ type: String, _ payload: [String: Any]) -> Int {
        seq += 1
        let message: [String: Any] = [
            "v": Self.protocolVersion, "type": type, "ts": now(), "seq": seq, "payload": payload,
        ]
        // pose_update and test get no ack; remembering them would only grow the table.
        if type != "pose_update", type != "test" { sentTypes[seq] = type }
        if sentTypes.count > 64, let oldest = sentTypes.keys.min() { sentTypes[oldest] = nil }
        if let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            send(text)
        }
        return seq
    }
}
