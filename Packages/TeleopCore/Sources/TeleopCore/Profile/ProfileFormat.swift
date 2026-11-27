import Foundation

// The JSON form of a robot profile (docs/PROFILE.md). Keys are snake_case and carry their unit; vectors are arrays
// ([x, y, z] in the robot base frame, or [across, height]). Decoding is strict: every key must be there, a key the
// format does not know is refused, and an optional value is written as null rather than left out. A misspelt field
// therefore stops the load with its name instead of falling back to a default that belongs to another arm.

/// Why a profile file could not be read. Each case names the field by its path in the file, such as
/// `scene.tool_offset.offset_m`.
public enum ProfileFormatError: Error, Equatable, CustomStringConvertible {
    case missingKey(String)
    case unknownKey(String)
    case wrongLength(String, expected: Int, found: Int)
    case unsupportedVersion(Int)
    /// A value of the wrong kind (text where a number goes, say), or a file that is not JSON: the path is empty then.
    case badValue(String)
    /// The file was read but its values do not make sense together: one sentence per fault.
    case invalid([String])

    public var description: String {
        switch self {
        case .missingKey(let path): return "The profile has no \(path); every field must be given."
        case .unknownKey(let path): return "The profile has \(path), which is not a field of this format."
        case .wrongLength(let path, let expected, let found):
            return "\(path) must have \(expected) numbers, not \(found)."
        case .unsupportedVersion(let version):
            return "profile_version \(version) is not supported; this app reads version \(RobotProfile.formatVersion)."
        case .badValue(let path) where path.isEmpty: return "The profile is not a valid JSON object."
        case .badValue(let path): return "\(path) has a value of the wrong kind."
        case .invalid(let faults): return faults.joined(separator: " ")
        }
    }
}

extension RobotProfile: Codable {
    /// The `profile_version` this app writes and reads.
    public static let formatVersion = 1

    /// Reads a profile file and checks it: a format error, or `ProfileFormatError.invalid` with every sentence
    /// `validate()` gives.
    public static func load(json: Data) throws -> RobotProfile {
        let profile: RobotProfile
        do {
            profile = try JSONDecoder().decode(RobotProfile.self, from: json)
        } catch let error as DecodingError {
            throw ProfileFormatError.badValue(error.path)
        }
        let faults = profile.validate()
        guard faults.isEmpty else { throw ProfileFormatError.invalid(faults) }
        return profile
    }

    public init(from decoder: Decoder) throws {
        let top = try decoder.strictContainer(["profile_version", "name", "robot", "scene", "response", "assist"])
        let version: Int = try top.value("profile_version")
        guard version == Self.formatVersion else { throw ProfileFormatError.unsupportedVersion(version) }
        let robot = try top.section("robot", ["wrist", "gripper"])
        let wrist = try robot.section("wrist", ["roll_sign", "tilt_sign"])
        let gripper = try robot.section("gripper", ["open_deg", "empty_deg", "reclose_loosens_grip"])
        let scene = try top.section(
            "scene",
            [
                "base_in_world_m", "table_height_m", "workspace_min_m", "workspace_max_m", "target_size_m",
                "goal_size_m", "grasp_tolerance_m", "on_target_window_m", "tool_offset",
            ])
        let tool = try scene.section(
            "tool_offset", ["offset_m", "measured_at_m", "measured_flex_deg", "measured_roll_deg", "error_bound"])
        let response = try top.section("response", ["directional_blocked_feedback"])
        self.init(
            name: try top.value("name"),
            toolOffset: try tool.vector3("offset_m"),
            offsetMeasuredAt: try tool.vector3("measured_at_m"),
            offsetMeasuredFlexDeg: try tool.value("measured_flex_deg"),
            offsetMeasuredRollDeg: try tool.value("measured_roll_deg"),
            estimateBound: try tool.value("error_bound"),
            baseInWorld: try scene.vector3("base_in_world_m"),
            graspTolerance: try scene.vector2("grasp_tolerance_m"),
            targetSize: try scene.value("target_size_m"),
            goalSize: try scene.value("goal_size_m"),
            gripperOpenDeg: try gripper.value("open_deg"),
            gripperEmptyDeg: try gripper.value("empty_deg"),
            workspaceMin: try scene.vector3("workspace_min_m"),
            workspaceMax: try scene.vector3("workspace_max_m"),
            tableHeight: try scene.value("table_height_m"),
            rollSign: try wrist.value("roll_sign"),
            tiltSign: try wrist.value("tilt_sign"),
            recloseLoosensGrip: try gripper.value("reclose_loosens_grip"),
            usesDirectionalBlockedFeedback: try response.value("directional_blocked_feedback"),
            assist: try top.value("assist"),
            onTargetWindow: try scene.optionalVector2("on_target_window_m")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var top = encoder.container(keyedBy: ProfileKey.self)
        try top.encode(Self.formatVersion, forKey: "profile_version")
        try top.encode(name, forKey: "name")
        var robot = top.nestedContainer(keyedBy: ProfileKey.self, forKey: "robot")
        var wrist = robot.nestedContainer(keyedBy: ProfileKey.self, forKey: "wrist")
        try wrist.encode(rollSign, forKey: "roll_sign")
        try wrist.encode(tiltSign, forKey: "tilt_sign")
        var gripper = robot.nestedContainer(keyedBy: ProfileKey.self, forKey: "gripper")
        try gripper.encode(gripperOpenDeg, forKey: "open_deg")
        try gripper.encode(gripperEmptyDeg, forKey: "empty_deg")
        try gripper.encode(recloseLoosensGrip, forKey: "reclose_loosens_grip")
        var scene = top.nestedContainer(keyedBy: ProfileKey.self, forKey: "scene")
        try scene.encode(Self.array(baseInWorld), forKey: "base_in_world_m")
        try scene.encode(tableHeight, forKey: "table_height_m")
        try scene.encode(Self.array(workspaceMin), forKey: "workspace_min_m")
        try scene.encode(Self.array(workspaceMax), forKey: "workspace_max_m")
        try scene.encode(targetSize, forKey: "target_size_m")
        try scene.encode(goalSize, forKey: "goal_size_m")
        try scene.encode([graspTolerance.x, graspTolerance.y], forKey: "grasp_tolerance_m")
        try scene.encode(onTargetWindow.map { [$0.x, $0.y] }, forKey: "on_target_window_m")
        var tool = scene.nestedContainer(keyedBy: ProfileKey.self, forKey: "tool_offset")
        try tool.encode(Self.array(toolOffset), forKey: "offset_m")
        try tool.encode(Self.array(offsetMeasuredAt), forKey: "measured_at_m")
        try tool.encode(offsetMeasuredFlexDeg, forKey: "measured_flex_deg")
        try tool.encode(offsetMeasuredRollDeg, forKey: "measured_roll_deg")
        try tool.encode(estimateBound, forKey: "error_bound")
        var response = top.nestedContainer(keyedBy: ProfileKey.self, forKey: "response")
        try response.encode(usesDirectionalBlockedFeedback, forKey: "directional_blocked_feedback")
        try top.encode(assist, forKey: "assist")
    }

    private static func array(_ v: SIMD3<Float>) -> [Float] { [v.x, v.y, v.z] }
}

extension EstimateBound: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.strictContainer([
            "x_mm_per_cm", "plus_y_mm_per_cm", "minus_y_mm_per_cm", "z_mm_per_cm", "flex_mm_per_deg",
            "roll_mm_per_deg",
        ])
        self.init(
            xMmPerCm: try c.value("x_mm_per_cm"), plusYMmPerCm: try c.value("plus_y_mm_per_cm"),
            minusYMmPerCm: try c.value("minus_y_mm_per_cm"), zMmPerCm: try c.value("z_mm_per_cm"),
            flexMmPerDeg: try c.value("flex_mm_per_deg"), rollMmPerDeg: try c.value("roll_mm_per_deg"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: ProfileKey.self)
        try c.encode(xMmPerCm, forKey: "x_mm_per_cm")
        try c.encode(plusYMmPerCm, forKey: "plus_y_mm_per_cm")
        try c.encode(minusYMmPerCm, forKey: "minus_y_mm_per_cm")
        try c.encode(zMmPerCm, forKey: "z_mm_per_cm")
        try c.encode(flexMmPerDeg, forKey: "flex_mm_per_deg")
        try c.encode(rollMmPerDeg, forKey: "roll_mm_per_deg")
    }
}

extension AssistProfile: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.strictContainer(["lock", "go_to", "guide", "explain", "views"])
        self.init(
            lock: try c.optional("lock"), goTo: try c.optional("go_to"), guide: try c.optional("guide"),
            explain: try c.optional("explain"), views: try c.optional("views"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: ProfileKey.self)
        try c.encode(lock, forKey: "lock")
        try c.encode(goTo, forKey: "go_to")
        try c.encode(guide, forKey: "guide")
        try c.encode(explain, forKey: "explain")
        try c.encode(views, forKey: "views")
    }
}

extension LockLimits: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.strictContainer(["time_limit_s"])
        self.init(timeLimitS: try c.value("time_limit_s"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: ProfileKey.self)
        try c.encode(timeLimitS, forKey: "time_limit_s")
    }
}

extension GoToLimits: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.strictContainer([
            "travel_height_m", "speed_mps", "arrive_tolerance_m", "corrections", "correction_reach_m", "settle_s",
            "time_factor", "allowance_s", "arm_data_timeout_s", "start_grace_s",
        ])
        self.init(
            travelHeightM: try c.value("travel_height_m"), speedMps: try c.value("speed_mps"),
            arriveToleranceM: try c.value("arrive_tolerance_m"), corrections: try c.value("corrections"),
            correctionReachM: try c.value("correction_reach_m"), settleS: try c.value("settle_s"),
            timeFactor: try c.value("time_factor"), allowanceS: try c.value("allowance_s"),
            armDataTimeoutS: try c.value("arm_data_timeout_s"), startGraceS: try c.value("start_grace_s"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: ProfileKey.self)
        try c.encode(travelHeightM, forKey: "travel_height_m")
        try c.encode(speedMps, forKey: "speed_mps")
        try c.encode(arriveToleranceM, forKey: "arrive_tolerance_m")
        try c.encode(corrections, forKey: "corrections")
        try c.encode(correctionReachM, forKey: "correction_reach_m")
        try c.encode(settleS, forKey: "settle_s")
        try c.encode(timeFactor, forKey: "time_factor")
        try c.encode(allowanceS, forKey: "allowance_s")
        try c.encode(armDataTimeoutS, forKey: "arm_data_timeout_s")
        try c.encode(startGraceS, forKey: "start_grace_s")
    }
}

extension GuideAids: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.strictContainer([
            "work_area_words", "lowest_cue", "shadow", "direction_labels", "wider_on_target",
        ])
        self.init(
            workAreaWords: try c.value("work_area_words"), lowestCue: try c.value("lowest_cue"),
            shadow: try c.value("shadow"), directionLabels: try c.value("direction_labels"),
            widerOnTarget: try c.value("wider_on_target"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: ProfileKey.self)
        try c.encode(workAreaWords, forKey: "work_area_words")
        try c.encode(lowestCue, forKey: "lowest_cue")
        try c.encode(shadow, forKey: "shadow")
        try c.encode(directionLabels, forKey: "direction_labels")
        try c.encode(widerOnTarget, forKey: "wider_on_target")
    }
}

extension ExplainAids: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.strictContainer(["slow_link_let_go"])
        self.init(slowLinkLetGo: try c.value("slow_link_let_go"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: ProfileKey.self)
        try c.encode(slowLinkLetGo, forKey: "slow_link_let_go")
    }
}

extension ViewAim: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.strictContainer(["behind_top_above_table_m", "max_retargeted_move_s"])
        self.init(
            behindTopAboveTableM: try c.value("behind_top_above_table_m"),
            maxRetargetedMoveS: try c.optional("max_retargeted_move_s"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: ProfileKey.self)
        try c.encode(behindTopAboveTableM, forKey: "behind_top_above_table_m")
        try c.encode(maxRetargetedMoveS, forKey: "max_retargeted_move_s")
    }
}

// MARK: Strict decoding

extension DecodingError {
    /// Where in the file the error is, such as `scene.target_size_m`; empty for the file as a whole.
    fileprivate var path: String {
        let context: Context
        switch self {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .keyNotFound(_, let c), .dataCorrupted(let c):
            context = c
        @unknown default: return ""
        }
        return context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
    }
}

/// A key of the profile format, written as the string it is in the file.
struct ProfileKey: CodingKey, ExpressibleByStringLiteral {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
    init(stringLiteral value: String) { stringValue = value }
}

/// A JSON object of the profile format whose keys have been checked against the ones it must have.
struct StrictObject {
    let container: KeyedDecodingContainer<ProfileKey>

    /// `scene.tool_offset.offset_m` for a key of this object.
    func path(_ key: String) -> String {
        (container.codingPath.map(\.stringValue) + [key]).joined(separator: ".")
    }

    func value<T: Decodable>(_ key: String) throws -> T {
        guard container.contains(ProfileKey(stringValue: key)) else { throw ProfileFormatError.missingKey(path(key)) }
        return try container.decode(T.self, forKey: ProfileKey(stringValue: key))
    }

    /// A value that may be null, but whose key must still be written.
    func optional<T: Decodable>(_ key: String) throws -> T? {
        guard container.contains(ProfileKey(stringValue: key)) else { throw ProfileFormatError.missingKey(path(key)) }
        if try container.decodeNil(forKey: ProfileKey(stringValue: key)) { return nil }
        return try container.decode(T.self, forKey: ProfileKey(stringValue: key))
    }

    func section(_ key: String, _ keys: [String]) throws -> StrictObject {
        guard container.contains(ProfileKey(stringValue: key)) else { throw ProfileFormatError.missingKey(path(key)) }
        let nested = try container.nestedContainer(keyedBy: ProfileKey.self, forKey: ProfileKey(stringValue: key))
        return try StrictObject(checking: nested, keys)
    }

    func vector3(_ key: String) throws -> SIMD3<Float> {
        let numbers = try numbers(key, count: 3)
        return SIMD3(numbers[0], numbers[1], numbers[2])
    }

    func vector2(_ key: String) throws -> SIMD2<Float> {
        let numbers = try numbers(key, count: 2)
        return SIMD2(numbers[0], numbers[1])
    }

    func optionalVector2(_ key: String) throws -> SIMD2<Float>? {
        guard container.contains(ProfileKey(stringValue: key)) else { throw ProfileFormatError.missingKey(path(key)) }
        if try container.decodeNil(forKey: ProfileKey(stringValue: key)) { return nil }
        return try vector2(key)
    }

    private func numbers(_ key: String, count: Int) throws -> [Float] {
        let numbers: [Float] = try value(key)
        guard numbers.count == count else {
            throw ProfileFormatError.wrongLength(path(key), expected: count, found: numbers.count)
        }
        return numbers
    }

    init(checking container: KeyedDecodingContainer<ProfileKey>, _ keys: [String]) throws {
        self.container = container
        let expected = Set(keys)
        if let unknown = container.allKeys.map(\.stringValue).filter({ !expected.contains($0) }).sorted().first {
            throw ProfileFormatError.unknownKey(path(unknown))
        }
        if let missing = keys.first(where: { !container.contains(ProfileKey(stringValue: $0)) }) {
            throw ProfileFormatError.missingKey(path(missing))
        }
    }
}

extension Decoder {
    func strictContainer(_ keys: [String]) throws -> StrictObject {
        try StrictObject(checking: container(keyedBy: ProfileKey.self), keys)
    }
}
