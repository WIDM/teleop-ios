/// When the on-target cue plays (`FeedbackEvent.onTarget`), so the operator can feel the jaws arrive on the target and
/// keep watching the arm. Pure: time is passed in, in milliseconds.
///
/// It plays once as "on target" turns true: a target is reported, the pinch point is inside the window around it,
/// the marker is not approximate, nothing is held, the task aid is on and the jaws are open. The stop being latched
/// keeps it silent. It is armed again only after the pinch point has left a window `rearmScale` times as large, or
/// after a close (the jaws seen closed), a scene reset (`rearm`) or a new target (one reported after none). Jaws
/// whose state is not known neither play it nor arm it.
public struct OnTargetCue {
    public static let rearmScale = 1.5

    /// What the guide shows at one moment.
    public struct Look: Equatable, Sendable {
        /// From the reported target to the pinch point: across the table, and the pinch point's height above (+) or
        /// below (−) it, metres. Nil when no target is reported.
        public var gap: SIMD2<Double>?
        /// The pinch point is an estimate that may be off by more than half the window.
        public var approximate: Bool
        /// The jaws hold the target.
        public var holding: Bool
        public var taskAid: Bool
        /// Nil when the server does not say.
        public var jawsOpen: Bool?
        /// The emergency stop is latched.
        public var stopped: Bool

        public init(gap: SIMD2<Double>?, approximate: Bool, holding: Bool, taskAid: Bool, jawsOpen: Bool?, stopped: Bool) {
            self.gap = gap
            self.approximate = approximate
            self.holding = holding
            self.taskAid = taskAid
            self.jawsOpen = jawsOpen
            self.stopped = stopped
        }
    }

    /// The on-target window across the table and in height, metres: the robot profile's grasp tolerance.
    public let window: SIMD2<Double>
    private var armed = true
    private var hadTarget = false
    /// When the cue last played.
    public private(set) var playedAtMs: Int?

    public init(window: SIMD2<Double>) {
        self.window = window
    }

    /// `gap` is inside `window`: across within its first number, the height either way within its second.
    public static func inside(_ gap: SIMD2<Double>, window: SIMD2<Double>) -> Bool {
        gap.x <= window.x && abs(gap.y) <= window.y
    }

    /// One look at the guide. True when the cue plays now.
    public mutating func observe(_ look: Look, at now: Int) -> Bool {
        defer { hadTarget = look.gap != nil }
        guard let gap = look.gap else { return false }
        if !hadTarget || look.jawsOpen == false || !Self.inside(gap, window: window * Self.rearmScale) { armed = true }
        let onTarget = Self.inside(gap, window: window) && !look.approximate && !look.holding && look.taskAid
            && look.jawsOpen == true
        guard armed, onTarget, !look.stopped else { return false }
        armed = false
        playedAtMs = now
        return true
    }

    /// The scene was reset: the next approach plays again.
    public mutating func rearm() {
        armed = true
    }
}
