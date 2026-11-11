public enum TeleopMode: Sendable { case onSite, cloud }
public enum ArmSide: Sendable { case left, right }
public enum GripperState: Sendable { case open, closed }
/// Which way the wrist moves under a held wrist control. `positive` and `negative` roll it, turning the jaws about
/// the forearm axis (positive is the direction the server's wrist roll increases). `tiltDown` and `tiltUp` pitch it,
/// pointing the jaws more toward the table or away from it.
public enum TurnDirection: Sendable {
    case positive, negative, tiltDown, tiltUp

    public var isTilt: Bool { self == .tiltDown || self == .tiltUp }
}

/// UI state. Fake by default; with `liveLink` set, `connected`, latency and E-stop follow the server.
public struct FakeTeleopState: Equatable, Sendable {
    public var mode: TeleopMode = .onSite
    public var connected = false
    public var heartbeatOk = true
    public var physicalEstopOk = true
    public var latencyMs = 80
    public var commandsBlocked = false
    public var gripper: GripperState = .open
    public var arm: ArmSide = .left
    public var serverAddress = ""
    public var tutorialDone = false
    public var emergencyStop = false
    public var isRecording = false
    public var recordingElapsedSec = 0
    public var developerMode = false
    public var sensitivity = 1.0
    public private(set) var smoothing = 0.3
    /// True while the arm hold (vol+ or the on-screen hold area) is pressed.
    public var armMoving = false
    /// Direction the gripper is travelling while its control is held; nil when still.
    public var gripperMoving: GripperState?
    /// Which way the wrist is moving while a wrist control is held (roll or pitch); nil when still.
    public var jawTurning: TurnDirection?
    public var serverInputError = false
    /// True when a real server drives the link. Then only `linkUp` marks the session connected.
    public var liveLink = false

    public init() {}

    public static let normalLatencyMs = 80
    public static let amberLatencyMs = 150
    /// Round trip at or above this blocks commands.
    public static let blockLatencyMs = 400
    public static let smoothingRange = 0.0...1.0

    public var latencyIsAmber: Bool {
        commandsBlocked || latencyMs >= Self.amberLatencyMs
    }

    public mutating func selectCloud() { mode = .cloud }
    public mutating func selectOnSite() { mode = .onSite }

    public mutating func markConnected() {
        connected = true
        latencyMs = Self.normalLatencyMs
        commandsBlocked = false
    }

    public mutating func markDisconnected() {
        connected = false
        heartbeatOk = false
        armMoving = false
        gripperMoving = nil
        jawTurning = nil
    }

    public mutating func simulateCloudPass() {
        heartbeatOk = true
        physicalEstopOk = true
        markConnected()
    }

    public mutating func simulateCloudFail() {
        heartbeatOk = false
        physicalEstopOk = true
        connected = true
    }

    public mutating func clearLatency() {
        latencyMs = Self.normalLatencyMs
        commandsBlocked = false
    }

    /// Back to mode select: the link is dropped and nothing keeps moving or recording.
    public mutating func leaveSession() {
        armMoving = false
        gripperMoving = nil
        jawTurning = nil
        isRecording = false
        connected = false
        heartbeatOk = true
        clearLatency()
    }

    /// Reset scene: arm stopped, gripper back to open, latency block cleared. Recording keeps running.
    public mutating func resetScene() {
        armMoving = false
        gripperMoving = nil
        jawTurning = nil
        gripper = .open
        clearLatency()
    }

    public mutating func setSmoothing(_ value: Double) {
        smoothing = min(max(value, Self.smoothingRange.lowerBound), Self.smoothingRange.upperBound)
    }

    /// The gripper starts travelling toward `target` and keeps going until `stopGripper`.
    public mutating func moveGripper(toward target: GripperState) {
        gripperMoving = target
        gripper = target
    }

    public mutating func stopGripper() { gripperMoving = nil }

    public mutating func turnJaws(toward direction: TurnDirection) { jawTurning = direction }

    public mutating func stopTurn() { jawTurning = nil }

    public mutating func startRecording() {
        isRecording = true
        recordingElapsedSec = 0
    }

    public mutating func stopRecording() { isRecording = false }

    public mutating func tickRecording() {
        if isRecording { recordingElapsedSec += 1 }
    }

    /// mm:ss, zero padded (visual-spec v1.1).
    public var recordingTimeLabel: String {
        let minutes = recordingElapsedSec / 60
        let seconds = recordingElapsedSec % 60
        return (minutes < 10 ? "0" : "") + String(minutes) + ":" + (seconds < 10 ? "0" : "") + String(seconds)
    }
}
