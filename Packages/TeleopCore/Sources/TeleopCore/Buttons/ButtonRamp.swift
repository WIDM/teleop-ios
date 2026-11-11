/// Buttons-mode speed, chosen with the Fine / Coarse switch (INTERACTION §3.2, §3.3). Coarse is the default.
public enum ButtonSpeed: String, CaseIterable, Sendable {
    case fine, coarse

    /// How fast a held direction button moves the arm's target, in wall time (Appendix A `buttonsTranslate`).
    public var metresPerSecond: Double {
        switch self {
        case .fine: return 0.01
        case .coarse: return 0.04
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
    public private(set) var frozenAtMs: Int?

    public init(direction: OperatorDirection, speed: ButtonSpeed, startMs: Int) {
        self.direction = direction
        self.speed = speed
        self.startMs = startMs
    }

    /// How far the target has moved, metres.
    public func distance(atMs nowMs: Int) -> Double {
        let end = frozenAtMs.map { min($0, nowMs) } ?? nowMs
        return speed.metresPerSecond * Double(max(0, end - startMs)) / 1000
    }

    /// The offset to send at `nowMs`.
    public func offset(atMs nowMs: Int) -> SIMD3<Double> {
        direction.linkVector * distance(atMs: nowMs)
    }

    /// The target stays where it is at `nowMs` from now on. A second freeze changes nothing.
    public mutating func freeze(atMs nowMs: Int) {
        guard frozenAtMs == nil else { return }
        frozenAtMs = max(startMs, nowMs)
    }
}
