import Foundation

/// The server's message checks, with its error codes. Each returns nil for a valid message.
enum Validation {
    static let supportedTypes: Set<String> = [
        "hello", "test", "move_delta", "jog_start", "jog_keepalive", "jog_stop", "joint_jog_start", "joint_jog_stop",
        "gripper_jog_start", "gripper_jog_stop", "orient_start", "orient_update", "orient_stop", "pose_start",
        "pose_update", "pose_stop", "joint_delta", "gripper", "mode", "estop", "estop_reset", "reset_scene",
    ]
    private static let steps: Set<String> = ["coarse", "fine"]
    private static let armJoints: Set<String> = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll"]

    /// The envelope `{v, type, ts, seq, payload}`: the seq to answer with, the code and the message.
    static func envelope(_ message: JSONValue) -> (Int, String, String)? {
        guard let keys = message.keys else { return (-1, "invalid_message", "message must be a JSON object") }
        let safeSeq = message["seq"]?.intValue ?? -1
        let missing = ["payload", "seq", "ts", "type", "v"].filter { !keys.contains($0) }
        if !missing.isEmpty {
            return (safeSeq, "missing_fields", "missing fields: [\(missing.map { "'\($0)'" }.joined(separator: ", "))]")
        }
        guard let version = message["v"]?.intValue, version == 0 || version == 1 else {
            return (safeSeq, "unsupported_version", "supported versions are v=0 and v=1")
        }
        guard let type = message["type"]?.stringValue else { return (safeSeq, "invalid_type", "type must be a string") }
        guard message["ts"]?.intValue != nil else { return (safeSeq, "invalid_ts", "ts must be an integer in milliseconds") }
        guard let seq = message["seq"]?.intValue, seq >= 0 else {
            return (-1, "invalid_seq", "seq must be a non-negative integer")
        }
        guard message["payload"]?.keys != nil else { return (safeSeq, "invalid_payload", "payload must be a JSON object") }
        guard supportedTypes.contains(type) else { return (safeSeq, "unknown_type", "unsupported type=\(type)") }
        return nil
    }

    /// Starts and one-shot commands: the code their refusal acks with.
    static func command(_ kind: String, _ payload: JSONValue) -> String? {
        switch kind {
        case "move_delta": return moveDelta(payload)
        case "jog_start": return moveDelta(payload).map { "jog_" + $0 }
        case "joint_jog_start", "joint_delta": return jointDelta(payload)
        case "gripper_jog_start":
            guard payload.keys == ["action", "step"] else { return "invalid_gripper_jog_start" }
            guard ["open", "close"].contains(payload["action"]?.stringValue) else { return "invalid_gripper_action" }
            guard steps.contains(payload["step"]?.stringValue ?? "") else { return "invalid_step" }
            return nil
        case "gripper":
            guard payload.keys == ["action"] else { return "invalid_gripper" }
            guard ["open", "close"].contains(payload["action"]?.stringValue) else { return "invalid_gripper_action" }
            return nil
        case "orient_start": return orientStart(payload)
        case "pose_start": return poseStart(payload)
        default: return nil
        }
    }

    private static func moveDelta(_ payload: JSONValue) -> String? {
        let keys = payload.keys ?? []
        guard keys.isSuperset(of: ["axis", "dir", "step"]), keys.isSubset(of: ["axis", "dir", "step", "frame"]) else {
            return "invalid_move_delta"
        }
        let axis = payload["axis"]?.stringValue ?? ""
        guard ["x", "y", "z", "rx", "ry", "rz"].contains(axis) else { return "invalid_axis" }
        guard ["x", "y", "z"].contains(axis) else { return "rotation_not_supported" }
        guard let direction = payload["dir"]?.intValue, direction == 1 || direction == -1 else { return "invalid_dir" }
        guard steps.contains(payload["step"]?.stringValue ?? "") else { return "invalid_step" }
        let frame = payload["frame"] ?? "base"
        guard frame == "base" || frame == "tool" else { return "invalid_frame" }
        return nil
    }

    private static func jointDelta(_ payload: JSONValue) -> String? {
        guard payload.keys == ["joint", "dir", "step"] else { return "invalid_joint_delta" }
        guard armJoints.contains(payload["joint"]?.stringValue ?? "") else { return "invalid_joint" }
        guard let direction = payload["dir"]?.intValue, direction == 1 || direction == -1 else { return "invalid_dir" }
        guard steps.contains(payload["step"]?.stringValue ?? "") else { return "invalid_step" }
        return nil
    }

    private static func orientStart(_ payload: JSONValue) -> String? {
        guard payload.keys == ["frame", "rate_hz", "gain", "deadband_deg", "smoothing"] else { return "invalid_orient_start" }
        guard payload["frame"]?.stringValue == "phone_body" else { return "invalid_orient_frame" }
        guard payload["rate_hz"]?.intValue == 30 else { return "invalid_orient_rate" }
        guard parametersInRange(payload) else { return "invalid_orient_parameter" }
        return nil
    }

    private static func poseStart(_ payload: JSONValue) -> String? {
        let required: Set<String> = ["frame", "rate_hz", "gain", "deadband_deg", "smoothing"]
        let keys = payload.keys ?? []
        guard keys.isSuperset(of: required), keys.isSubset(of: required.union(["control_mode"])) else {
            return "invalid_pose_start"
        }
        let mode = payload["control_mode"] == nil ? "translation" : payload["control_mode"]?.stringValue
        guard mode == "translation" || mode == "wrist" else { return "invalid_pose_control_mode" }
        guard payload["frame"]?.stringValue == "webxr_local" else { return "invalid_pose_frame" }
        guard payload["rate_hz"]?.intValue == 30 else { return "invalid_pose_rate" }
        guard parametersInRange(payload) else { return "invalid_pose_parameter" }
        return nil
    }

    /// gain, deadband_deg and smoothing: checked, and then ignored by the server.
    private static func parametersInRange(_ payload: JSONValue) -> Bool {
        let limits: [(String, ClosedRange<Double>)] = [("gain", 0.1...2.0), ("deadband_deg", 0...15), ("smoothing", 0...0.95)]
        return limits.allSatisfy { field, range in
            guard let value = payload[field]?.numberValue, value.isFinite else { return false }
            return range.contains(value)
        }
    }

    static func mode(_ payload: JSONValue) -> String? {
        guard payload.keys == ["step"], steps.contains(payload["step"]?.stringValue ?? "") else { return "invalid_mode" }
        return nil
    }

    static func orientUpdate(_ payload: JSONValue) -> (String, String)? {
        guard payload.keys == ["q_rel"] else { return ("invalid_orient_update", "payload must contain only q_rel") }
        return quaternion(payload["q_rel"])
    }

    private static func quaternion(_ value: JSONValue?) -> (String, String)? {
        guard let q = finiteNumbers(value), q.count == 4 else {
            return ("invalid_orient_quaternion", "q_rel must be four finite numbers")
        }
        let norm = q.map { $0 * $0 }.reduce(0, +).squareRoot()
        guard (0.98...1.02).contains(norm) else { return ("invalid_orient_quaternion", "q_rel must be a unit quaternion") }
        return nil
    }

    static func poseUpdate(_ payload: JSONValue) -> (String, String)? {
        guard payload.keys == ["p_rel_m", "q_rel", "gripper_delta"] else {
            return ("invalid_pose_update", "payload must contain only p_rel_m, q_rel, and gripper_delta")
        }
        guard let p = finiteNumbers(payload["p_rel_m"]), p.count == 3 else {
            return ("invalid_pose_position", "p_rel_m must be three finite numbers")
        }
        if let (_, msg) = quaternion(payload["q_rel"]) { return ("invalid_pose_quaternion", msg) }
        guard let delta = payload["gripper_delta"]?.numberValue, delta.isFinite, (-1.0...1.0).contains(delta) else {
            return ("invalid_pose_gripper_delta", "gripper_delta must be finite and within [-1, 1]")
        }
        return nil
    }

    /// An array of finite numbers, nil if anything in it is not one.
    private static func finiteNumbers(_ value: JSONValue?) -> [Double]? {
        guard let array = value?.arrayValue else { return nil }
        let numbers = array.compactMap(\.numberValue)
        guard numbers.count == array.count, numbers.allSatisfy(\.isFinite) else { return nil }
        return numbers
    }

    /// The numbers of an array already checked by `finiteNumbers`.
    static func numbers(_ value: JSONValue?) -> [Double] { finiteNumbers(value) ?? [] }
}
