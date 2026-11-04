public enum TeleopMode: Sendable { case onSite, cloud }
public enum ArmSide: Sendable { case left, right }
public enum GripperState: Sendable { case open, closed }

/// Fake UI state only; no networking.
public struct FakeTeleopState: Equatable, Sendable {
    public var mode: TeleopMode = .onSite
    public var connected = false
    public var heartbeatOk = true
    public var physicalEstopOk = true
    public var latencyMs = 80
    public var commandsBlocked = false
    public var gripper: GripperState = .open
    public var arm: ArmSide = .left
    public var serverAddress = "192.168.x.x:8765"
    public var tutorialDone = false
    public var emergencyStop = false
    public var isRecording = false
    public var recordingElapsedSec = 0
    public var developerMode = false
    public var sensitivity = 1.0
    public var serverInputError = false

    public init() {}

    public static let highLatencyMs = 420
    public static let normalLatencyMs = 80
    public static let amberLatencyMs = 150

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

    public mutating func simulateHighLatency() {
        latencyMs = Self.highLatencyMs
        commandsBlocked = true
    }

    public mutating func simulateNormalLatency() {
        latencyMs = Self.normalLatencyMs
        commandsBlocked = false
    }

    public mutating func toggleGripper() {
        gripper = gripper == .open ? .closed : .open
    }

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
