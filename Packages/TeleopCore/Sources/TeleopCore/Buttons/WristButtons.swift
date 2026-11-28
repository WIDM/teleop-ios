import Foundation

/// The fine panel's wrist page: hold a button to turn or tilt the wrist at a fixed rate, let go to stop. Each one
/// sends the same wrist hold (`orient_start`, `orient_update`, `orient_stop`) the phone's rotation sends, with the
/// angle growing at its rate instead of following the phone.
public enum WristButton: String, CaseIterable, Sendable {
    case tiltUp, tiltDown, turnLeft, turnRight

    public var axis: WristAxis {
        switch self {
        case .tiltUp, .tiltDown: return .tilt
        case .turnLeft, .turnRight: return .turn
        }
    }

    /// Server degrees a second for this arm, sign included: the button's rate from the wrist profile, times the
    /// profile's sign for its axis, the same sign the phone's turn and tilt use. Turn right and Tilt down count
    /// positive in the operator's terms: a turn clockwise as the operator sees the screen, and the jaws toward the
    /// table (the top of the phone away from the operator).
    public func degreesPerSecond(in wrist: WristProfile) -> Double {
        switch self {
        case .tiltDown: return wrist.tiltSign * wrist.tiltRateDegS
        case .tiltUp: return -wrist.tiltSign * wrist.tiltRateDegS
        case .turnRight: return wrist.rollSign * wrist.turnRateDegS
        case .turnLeft: return -wrist.rollSign * wrist.turnRateDegS
        }
    }
}

/// One wrist button's hold: the angle it asks for at each moment. The angle counts from when the hold's start went
/// on the wire, since a start can wait behind a finishing hold, and stays inside the range the phone's wrist hold has
/// (`RotationMapper.limits`).
public struct WristButtonRamp: Equatable, Sendable {
    public let button: WristButton
    public let range: ClosedRange<Double>
    /// Server degrees a second, from the arm's wrist profile.
    public let degreesPerSecond: Double
    /// When `orient_start` went out; nil while it waits.
    public private(set) var startedAt: TimeInterval?

    public init(button: WristButton, range: ClosedRange<Double>, wrist: WristProfile) {
        self.button = button
        self.range = range
        degreesPerSecond = button.degreesPerSecond(in: wrist)
    }

    public mutating func started(at time: TimeInterval) {
        if startedAt == nil { startedAt = time }
    }

    /// The angle unclamped, so a caller can tell the limit from the angle.
    private func asked(at time: TimeInterval) -> Double {
        guard let startedAt else { return 0 }
        return degreesPerSecond * max(0, time - startedAt)
    }

    /// The hold's target at `time`: the anchor until the start went out, then the rate times the time since, held to
    /// `range`.
    public func target(at time: TimeInterval) -> WristTarget {
        guard startedAt != nil else { return WristTarget(axis: button.axis, degrees: 0) }
        return WristTarget(axis: button.axis, degrees: min(max(asked(at: time), range.lowerBound), range.upperBound))
    }

    /// The angle has reached the end of `range` in the button's direction.
    public func atLimit(at time: TimeInterval) -> Bool {
        let angle = asked(at: time)
        return degreesPerSecond > 0 ? angle >= range.upperBound : angle <= range.lowerBound
    }
}
