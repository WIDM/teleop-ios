import simd

/// When the on-target cue plays (`FeedbackEvent.onTarget`), so the operator can feel the jaws arrive on the target and
/// keep watching the arm. Pure: time is passed in, in milliseconds.
///
/// It plays once as "on target" turns true: a target is reported, the pinch point is inside the window around it,
/// the marker is not approximate, nothing is held, the task aid is on and the jaws are open. The stop being latched
/// keeps it silent. It is armed again only after the pinch point has left a window `rearmScale` times as large, or
/// after a scene reset (`rearm`) or a new target (one reported after none), or after a close: when the jaws, seen
/// closed, open again with the target still inside that larger window around where it was as they closed (a miss, or
/// a grasp that did not lift it), wherever the jaws went meanwhile. Holding the target ends the approach. Jaws that
/// carried the target elsewhere and let go of it, which leaves the open jaws on it, play nothing. Jaws whose state is
/// not known neither play it nor arm it.
public struct OnTargetCue {
    public static let rearmScale = 1.5

    /// What the guide shows at one moment.
    public struct Look: Equatable, Sendable {
        /// From the reported target to the pinch point: across the table, and the pinch point's height above (+) or
        /// below (−) it, metres. Nil when no target is reported.
        public var gap: SIMD2<Double>?
        /// Where the reported target is, metres, in a frame whose third axis points up (the operator's right, forward
        /// and up). Nil when no target is reported.
        public var target: SIMD3<Double>?
        /// The pinch point is an estimate that may be off by more than half the window.
        public var approximate: Bool
        /// The jaws hold the target.
        public var holding: Bool
        public var taskAid: Bool
        /// From the server's jaws label: `open` is open, `closed` or `close` is closed. Nil when it does not say.
        public var jawsOpen: Bool?
        /// The emergency stop is latched, or the state being looked at reports one (`estop`).
        public var stopped: Bool

        public init(
            gap: SIMD2<Double>?, target: SIMD3<Double>?, approximate: Bool, holding: Bool, taskAid: Bool,
            jawsOpen: Bool?, stopped: Bool
        ) {
            self.gap = gap
            self.target = target
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
    /// Where the target was when the jaws were first seen closed since they were last seen open.
    private var targetAtClose: SIMD3<Double>?
    /// When the cue last played.
    public private(set) var playedAtMs: Int?

    public init(window: SIMD2<Double>) {
        self.window = window
    }

    /// `gap` is inside `window`: across within its first number, the height either way within its second.
    public static func inside(_ gap: SIMD2<Double>, window: SIMD2<Double>) -> Bool {
        gap.x <= window.x && abs(gap.y) <= window.y
    }

    /// From `a` to `b` as a gap: the distance across (the first two axes) and the rise (the third).
    static func gap(from a: SIMD3<Double>, to b: SIMD3<Double>) -> SIMD2<Double> {
        SIMD2(simd_length(SIMD2(b.x - a.x, b.y - a.y)), b.z - a.z)
    }

    /// One look at the guide. True when the cue plays now.
    public mutating func observe(_ look: Look, at now: Int) -> Bool {
        defer { hadTarget = look.gap != nil }
        guard let gap = look.gap, let target = look.target else { return false }
        let wider = window * Self.rearmScale
        if !hadTarget || !Self.inside(gap, window: wider) { armed = true }
        // Holding ends the approach, played or not; only opening on a target that stayed put arms it again.
        if look.holding { armed = false }
        if look.jawsOpen == false, targetAtClose == nil { targetAtClose = target }
        if look.jawsOpen == true, let before = targetAtClose {
            targetAtClose = nil
            if Self.inside(Self.gap(from: before, to: target), window: wider) { armed = true }
        }
        let onTarget = Self.inside(gap, window: window) && !look.approximate && !look.holding && look.taskAid
            && look.jawsOpen == true
        guard armed, onTarget, !look.stopped else { return false }
        armed = false
        playedAtMs = now
        return true
    }

    /// The scene was reset: the next approach plays again. The app calls it on a new `episode`, and on a server that
    /// reports no episode, on the first `state` after the reset's answer whose `ik` is not `resetting`.
    public mutating func rearm() {
        armed = true
        targetAtClose = nil
    }
}
