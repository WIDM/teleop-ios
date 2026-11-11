/// A way out of the emergency-stop state.
public enum StopExit: Equatable, Sendable {
    /// Reset the scene: clears the stop and arms the recorder again.
    case resetScene
    /// Release the stop and keep the scene as it is (`estop_reset`). The recorder stays off until a reset.
    case releaseKeepScene
}

/// Which exits the emergency-stop state may offer (interaction specification §6.5). An emergency stop throws the
/// take away and `estop_reset` alone leaves the recorder off, so the next success would not be saved: with a
/// recorder, only a scene reset is offered.
public struct StopExits: Equatable, Sendable {
    public var exits: [StopExit]
    /// An unknown server: the screen adds "Recording, if any, stays off until a reset." beside Release, keep scene.
    public var recordingMayStayOff: Bool

    public init(exits: [StopExit], recordingMayStayOff: Bool) {
        self.exits = exits
        self.recordingMayStayOff = recordingMayStayOff
    }

    /// - Parameters:
    ///   - recorder: the newest recorder fields; nil for an unknown server.
    ///   - practice: the built-in demo, which has no server and no recorder.
    public static func offered(recorder: RecorderStatus?, practice: Bool = false) -> StopExits {
        if practice { return StopExits(exits: [.resetScene, .releaseKeepScene], recordingMayStayOff: false) }
        guard let recorder else { return StopExits(exits: [.resetScene, .releaseKeepScene], recordingMayStayOff: true) }
        return recorder.records
            ? StopExits(exits: [.resetScene], recordingMayStayOff: false)
            : StopExits(exits: [.resetScene, .releaseKeepScene], recordingMayStayOff: false)
    }
}
