/// Whether the jaws hold an object: the server reported contact for the last close, and nothing has let go of it
/// since. It decides the path a pad hold is sent on. Every change of the fact is a `Change`, applied in `apply` alone.
///
/// The pad's holds take the tool point while nothing is held. Carrying the simulator's cube on that path, the arm lifted
/// it in 1 of 10 trials, and in 7 the server refused moves once it was gripped. On the gripper link's path, as version
/// 1.1.0 sent every hold, the cube was lifted and placed in the goal in 9 of 10.
public struct ObjectHold: Equatable, Sendable {
    public enum Change: Equatable, Sendable {
        /// The server reported gripper contact for the close that ran last.
        case contactReported
        /// An open went on the wire. The server may still refuse it (another phone has control) and leave the jaws
        /// shut, so it lets go of nothing yet.
        case openSent
        /// The server refused the open that went out, or it never went out.
        case openRefused
        /// A state shows the server opening the jaws: it names the gripper open after an open went out.
        case jawsOpening
        /// The scene was reset: the server's answer to a reset, or a state naming a new episode.
        case sceneReset
        /// The control connection closed; a new one starts with nothing known.
        case reconnected
    }

    public private(set) var holding = false
    /// An open went out and neither its refusal nor a state showing the jaws opening has come since.
    private var openAwaitingStart = false
    /// The episode the newest state named on this connection.
    private var episode: Int?

    public init() {}

    public mutating func apply(_ change: Change) {
        switch change {
        case .contactReported: holding = true
        case .openSent: openAwaitingStart = true
        case .openRefused: openAwaitingStart = false
        case .jawsOpening:
            guard openAwaitingStart else { return }
            openAwaitingStart = false
            holding = false
        case .sceneReset:
            holding = false
            openAwaitingStart = false
        case .reconnected:
            holding = false
            openAwaitingStart = false
            episode = nil
        }
    }

    /// A state from either connection: one naming another episode than the last is a scene reset, and one naming the
    /// gripper open shows an open that went out running (the server names the gripper by the way it last drove it). A
    /// stop is not a change: the stop freezes the arm and the jaws stay closed on what they hold, so the carry goes on
    /// after the release on the same path.
    public mutating func stateArrived(_ state: ServerState) {
        if state.gripper == .open { apply(.jawsOpening) }
        guard let number = state.episode else { return }
        if let before = episode, before != number { apply(.sceneReset) }
        episode = number
    }

    /// The path of a pad, precision-panel or up and down hold. Nothing held: the tool point when the server has a
    /// calibration for it, with coordinated height for up and down where the server offers it. Held: the gripper
    /// link's path for every direction, with no coordinated height.
    public func padHoldPath(toolCalibrated: Bool, coordinatedHeight: Bool, vertical: Bool) -> PadHoldPath {
        if holding { return PadHoldPath(useToolPoint: false, toolMotion: nil) }
        let motion: PoseToolMotion? = coordinatedHeight && vertical ? .coordinatedHeight : nil
        return PadHoldPath(useToolPoint: toolCalibrated, toolMotion: motion)
    }
}

/// Which server path a translation hold asks for.
public struct PadHoldPath: Equatable, Sendable {
    /// The tool point; false is the gripper link's origin.
    public var useToolPoint: Bool
    public var toolMotion: PoseToolMotion?

    public init(useToolPoint: Bool, toolMotion: PoseToolMotion?) {
        self.useToolPoint = useToolPoint
        self.toolMotion = toolMotion
    }
}
