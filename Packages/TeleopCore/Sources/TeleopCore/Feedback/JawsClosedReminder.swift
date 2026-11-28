/// When the operating screen tells the operator to open the gripper before moving in.
///
/// The server starts every episode with the jaws closed. An operator who moves next to an object and only then opens
/// them sweeps it away with the opening jaw. So once an episode, on the first translation that starts while the jaws
/// are still closed as the episode began, the screen shows the reminder for a moment. It is shown only, never felt or
/// spoken, and the move itself goes on.
///
/// Closed is what the state reports about the jaws: the server's jaws label, or without one the measured jaw reading
/// against the robot profile's numbers (`GripperLimits`). Never the object's position, so it holds on any server and
/// any arm. Nothing is said while the jaws hold something (`ObjectHold.holding`) or a close has just ended in contact
/// (`FeedbackMonitor.gripping`), where closed jaws are right; nor during a stop, or while the simulator is paused or
/// not responding: then it stays owed. Jaws seen open this episode end it until the next episode: the operator knows
/// the way. A scene reset, a new episode and a new connection arm it again.
public struct JawsClosedReminder: Equatable, Sendable {
    /// What is known about the jaws and the robot as a translation starts.
    public struct Look: Equatable, Sendable {
        /// The server's jaws label; nil when it does not say.
        public var jaws: GripperState?
        /// The measured jaw reading, in the profile's unit; nil when not reported.
        public var jawDeg: Double?
        /// The jaws hold an object (`ObjectHold.holding`).
        public var holding: Bool
        /// A close ended in contact and nothing has opened since (`FeedbackMonitor.gripping`).
        public var gripping: Bool
        /// The emergency stop is latched, or the newest state reports one.
        public var stopped: Bool
        /// The simulator is paused or not responding.
        public var simulatorHalted: Bool

        public init(
            jaws: GripperState?, jawDeg: Double?, holding: Bool, gripping: Bool, stopped: Bool, simulatorHalted: Bool
        ) {
            self.jaws = jaws
            self.jawDeg = jawDeg
            self.holding = holding
            self.gripping = gripping
            self.stopped = stopped
            self.simulatorHalted = simulatorHalted
        }
    }

    public let limits: GripperLimits
    /// It has not been shown this episode, and the jaws have not been seen open since the episode began.
    public private(set) var armed = true
    /// The episode the newest state named on this connection.
    private var episode: Int?

    public init(limits: GripperLimits) {
        self.limits = limits
    }

    /// Whether the jaws are closed: the label when the server gives one, otherwise the measured reading, closed at or
    /// below `emptyAt` and open above it. Nil when neither is known.
    public static func jawsClosed(_ jaws: GripperState?, degrees: Double?, limits: GripperLimits) -> Bool? {
        if let jaws { return jaws == .closed }
        return degrees.map { $0 <= limits.emptyAt }
    }

    /// A state from either connection. One naming another episode than the last begins a new episode.
    public mutating func stateArrived(_ state: ServerState) {
        if let number = state.episode {
            if let before = episode, before != number { armed = true }
            episode = number
        }
        // While resetting, a state can still show the jaws of the episode before.
        guard state.activity != .resetting else { return }
        if Self.jawsClosed(state.gripper, degrees: state.gripperDeg, limits: limits) == false { armed = false }
    }

    /// A translation start went on the wire (pad, precision panel, up and down, a phone move, a move to a tapped point).
    /// True when the reminder is shown now.
    public mutating func translationStarted(_ look: Look) -> Bool {
        guard armed, !look.holding, !look.gripping, !look.stopped, !look.simulatorHalted,
            Self.jawsClosed(look.jaws, degrees: look.jawDeg, limits: limits) == true
        else { return false }
        armed = false
        return true
    }

    /// The server reset the scene, or a state named a new episode.
    public mutating func sceneReset() { armed = true }

    /// A new control connection was welcomed.
    public mutating func reconnected() {
        armed = true
        episode = nil
    }
}
