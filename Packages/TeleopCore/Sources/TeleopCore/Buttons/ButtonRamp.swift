/// Buttons-mode speed, chosen with the Fine / Coarse switch (INTERACTION §3.2, §3.3). Coarse is the default.
public enum ButtonSpeed: String, CaseIterable, Sendable {
    case fine, coarse

    /// How fast a held direction button moves the arm's target, in wall time: the profile's fine or coarse speed
    /// (`robot.motion`).
    public func metresPerSecond(in motion: MotionProfile) -> Double {
        switch self {
        case .fine: return motion.fineMps
        case .coarse: return motion.coarseMps
        }
    }
}

/// The target of one direction-button hold. From zero at the press, it moves along the button's direction at the
/// chosen speed of wall time, and stops moving once frozen: at the release, or when the arm stopped following
/// (§3.3). The offset is what the phone's motion would otherwise give, before the link's lead cap: metres, in the
/// frame `TeleopLink.poseUpdate(positionMeters:)` takes. Time is passed in, in milliseconds.
public struct ButtonRamp: Equatable, Sendable {
    public let direction: OperatorDirection
    public let speed: ButtonSpeed
    public let startMs: Int
    /// Which way the button's direction goes out in the link's frame.
    public let frames: Frames
    /// How fast each speed moves the target.
    public let motion: MotionProfile
    public private(set) var frozenAtMs: Int?

    public init(direction: OperatorDirection, speed: ButtonSpeed, startMs: Int, frames: Frames, motion: MotionProfile) {
        self.frames = frames
        self.motion = motion
        self.direction = direction
        self.speed = speed
        self.startMs = startMs
    }

    /// How far the target has moved, metres.
    public func distance(atMs nowMs: Int) -> Double {
        let end = frozenAtMs.map { min($0, nowMs) } ?? nowMs
        return speed.metresPerSecond(in: motion) * Double(max(0, end - startMs)) / 1000
    }

    /// The offset to send at `nowMs`.
    public func offset(atMs nowMs: Int) -> SIMD3<Double> {
        frames.linkVector(direction) * distance(atMs: nowMs)
    }

    /// The target stays where it is at `nowMs` from now on. A second freeze changes nothing.
    public mutating func freeze(atMs nowMs: Int) {
        guard frozenAtMs == nil else { return }
        frozenAtMs = max(startMs, nowMs)
    }
}
