/// How fast the arm is asked to move from the buttons, and how far a command may run ahead of the arm while a hold is
/// on. Metres and seconds.
public struct MotionProfile: Equatable, Sendable {
    /// How fast a held direction button moves the arm's target on the Fine and on the Coarse switch, metres a second of
    /// wall time.
    public var fineMps: Double
    public var coarseMps: Double
    /// The most a translation command may run ahead of where the server's hold began, metres, on the gripper link's
    /// path and on the tool point's path. Both must be under the server's stop distance (`ServerProfile`).
    public var maxLeadM: Float
    public var toolMaxLeadM: Float

    public init(fineMps: Double, coarseMps: Double, maxLeadM: Float, toolMaxLeadM: Float) {
        self.fineMps = fineMps
        self.coarseMps = coarseMps
        self.maxLeadM = maxLeadM
        self.toolMaxLeadM = toolMaxLeadM
    }
}

/// The part of the server's behaviour the app plans around. These are facts about the server that drives the arm, not
/// about the arm: a server that stops, restarts or reports differently needs other numbers here.
public struct ServerProfile: Equatable, Sendable {
    /// The server stops the arm for good when the position it is asked for is farther than this from where the arm
    /// is, metres. No command may ask for more (`MotionProfile.maxLeadM`, `toolMaxLeadM`).
    public var stopDistanceM: Double
    /// When a hold that has to catch up is ended and restarted.
    public var resync: ResyncTimes
    /// Which point a pad hold moves while the jaws hold an object.
    public var heldObjectPoint: HeldObjectPoint

    public init(stopDistanceM: Double, resync: ResyncTimes, heldObjectPoint: HeldObjectPoint) {
        self.stopDistanceM = stopDistanceM
        self.resync = resync
        self.heldObjectPoint = heldObjectPoint
    }
}

/// The server reports no arm position during a hold, so a command that has to run ahead of the arm is followed by ending
/// the server hold and starting the next one from where the arm got to. Milliseconds.
public struct ResyncTimes: Equatable, Sendable {
    /// How long a hold on the gripper link's path catches up before it is ended and restarted.
    public var afterMs: Int
    /// The same on the tool point's path.
    public var toolAfterMs: Int
    /// The longest wait for the server to finish the old hold during a resync before the operator's hold ends.
    public var timeoutMs: Int

    public init(afterMs: Int, toolAfterMs: Int, timeoutMs: Int) {
        self.afterMs = afterMs
        self.toolAfterMs = toolAfterMs
        self.timeoutMs = timeoutMs
    }
}

/// Which point a pad hold moves while the jaws hold an object.
public enum HeldObjectPoint: String, CaseIterable, Sendable {
    /// The gripper link's origin, whatever the pad holds: a server that lifts an object through the tool point badly.
    case gripperLink = "gripper_link"
    /// The tool point, held or not: a server that lifts fine through it.
    case toolPoint = "tool_point"
}
