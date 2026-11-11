import Foundation

/// What the server's recorder is doing, as `state.rec` names it.
public enum RecorderLabel: String, Equatable, Sendable {
    /// The server runs without a recorder.
    case none
    /// Recording, but nothing is being captured: after a success until the automatic reset, and after an
    /// emergency stop until a scene reset.
    case off
    /// Ready to capture: the take starts at the first command.
    case armed
    case capturing
}

/// The recorder fields of one `state`.
public struct RecorderStatus: Equatable, Sendable {
    public var label: RecorderLabel
    /// Demonstrations in the output file, earlier server runs included (the file is opened for appending).
    public var saved: Int
    /// Takes thrown away since the server started.
    public var discarded: Int
    /// Samples in the current take.
    public var samples: Int
    public var session: String?
    public var mode: String?

    public init(label: RecorderLabel, saved: Int = 0, discarded: Int = 0, samples: Int = 0, session: String? = nil, mode: String? = nil) {
        self.label = label
        self.saved = saved
        self.discarded = discarded
        self.samples = samples
        self.session = session
        self.mode = mode
    }

    /// True when the server records demonstrations (`rec` is anything but "none").
    public var records: Bool { label != .none }
}

/// What the server says it is doing (`state.ik`).
public enum ServerActivity: Equatable, Sendable {
    case poseTracking
    case poseClamped
    case orienting
    case orientClamped
    case gripperJogging
    case gripperContact
    case ok
    case stopped
    case taskSuccess
    case resetting
    case other(String)

    public init(_ label: String) {
        switch label {
        case "pose_tracking": self = .poseTracking
        case "pose_clamped": self = .poseClamped
        case "orienting": self = .orienting
        case "orient_clamped": self = .orientClamped
        case "gripper_jogging": self = .gripperJogging
        case "gripper_contact": self = .gripperContact
        case "ok": self = .ok
        case "stopped": self = .stopped
        case "task_success": self = .taskSuccess
        case "resetting": self = .resetting
        default: self = .other(label)
        }
    }
}

/// One `state` message, reduced to what the app reads. A field the server did not send is nil.
public struct ServerState: Equatable, Sendable {
    public var estop: Bool
    public var gripper: GripperState?
    public var activity: ServerActivity?
    /// Arm tip, task object and goal, metres; the arm in the robot base frame, the others in the world frame.
    public var endEffector: SIMD3<Double>?
    public var object: SIMD3<Double>?
    public var goal: SIMD3<Double>?
    public var taskSuccess: Bool?
    public var episode: Int?
    /// Nil when the state has no `rec` key: an unknown server, never "no recorder".
    public var recorder: RecorderStatus?
    /// Measured joint angles, degrees.
    public var wristFlexDeg: Double?
    public var wristRollDeg: Double?
    public var gripperDeg: Double?

    public init(
        estop: Bool = false, gripper: GripperState? = nil, activity: ServerActivity? = nil,
        endEffector: SIMD3<Double>? = nil, object: SIMD3<Double>? = nil, goal: SIMD3<Double>? = nil,
        taskSuccess: Bool? = nil, episode: Int? = nil, recorder: RecorderStatus? = nil,
        wristFlexDeg: Double? = nil, wristRollDeg: Double? = nil, gripperDeg: Double? = nil
    ) {
        self.estop = estop
        self.gripper = gripper
        self.activity = activity
        self.endEffector = endEffector
        self.object = object
        self.goal = goal
        self.taskSuccess = taskSuccess
        self.episode = episode
        self.recorder = recorder
        self.wristFlexDeg = wristFlexDeg
        self.wristRollDeg = wristRollDeg
        self.gripperDeg = gripperDeg
    }

    /// Reads a `state` payload. Fields of the wrong type count as missing.
    public init(payload: [String: Any]) {
        estop = payload["estop"] as? Bool ?? false
        gripper = (payload["gripper"] as? String).flatMap(Self.gripperState)
        activity = (payload["ik"] as? String).map(ServerActivity.init)
        endEffector = Self.vector(payload["ee_pos"])
        object = Self.vector(payload["object_pos"])
        goal = Self.vector(payload["goal_pos"])
        taskSuccess = payload["task_success"] as? Bool
        episode = Self.integer(payload["episode"])
        wristFlexDeg = Self.number(payload["wrist_flex_deg"])
        wristRollDeg = Self.number(payload["wrist_roll_deg"])
        gripperDeg = Self.number(payload["gripper_deg"])
        // An unrecognised label is treated like a missing key: the recorder's state is unknown.
        if let label = (payload["rec"] as? String).flatMap(RecorderLabel.init(rawValue:)) {
            recorder = RecorderStatus(
                label: label,
                saved: Self.integer(payload["rec_saved"]) ?? 0,
                discarded: Self.integer(payload["rec_discarded"]) ?? 0,
                samples: Self.integer(payload["rec_samples"]) ?? 0,
                session: payload["rec_session"] as? String,
                mode: payload["rec_mode"] as? String
            )
        }
    }

    /// Nothing can be started: the success is shown or the scene is resetting.
    public var simBusy: Bool {
        taskSuccess == true || activity == .taskSuccess || activity == .resetting
    }

    static func gripperState(_ text: String) -> GripperState? {
        switch text {
        case "open": return .open
        // The server starts with "closed" and says "close" after a closing command.
        case "closed", "close": return .closed
        default: return nil
        }
    }

    private static func vector(_ value: Any?) -> SIMD3<Double>? {
        guard let values = value as? [Any], values.count == 3 else { return nil }
        let numbers = values.compactMap(number)
        return numbers.count == 3 ? SIMD3(numbers[0], numbers[1], numbers[2]) : nil
    }

    private static func number(_ value: Any?) -> Double? {
        // JSONSerialization gives NSNumber; a Bool is an NSNumber too and must not read as 0 or 1.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    private static func integer(_ value: Any?) -> Int? {
        number(value).map { Int($0) }
    }
}
