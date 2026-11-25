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

    /// Server degrees a second, sign included. A positive pitch points the jaws toward the table (PROTOCOL.md,
    /// "the wrist"), so Tilt down is positive. Turn right is a positive roll, as seen in the top and side views.
    public var degreesPerSecond: Double {
        switch self {
        case .tiltDown: return Self.tiltRate
        case .tiltUp: return -Self.tiltRate
        case .turnRight: return Self.turnRate
        case .turnLeft: return -Self.turnRate
        }
    }

    public static let turnRate = 20.0
    public static let tiltRate = 10.0
}

/// One wrist button's hold: the angle it asks for at each moment. The angle counts from when the hold's start went
/// on the wire, since a start can wait behind a finishing hold, and stays inside the range the phone's wrist hold has
/// (`RotationMapper.limits`).
public struct WristButtonRamp: Equatable, Sendable {
    public let button: WristButton
    public let range: ClosedRange<Double>
    /// When `orient_start` went out; nil while it waits.
    public private(set) var startedAt: TimeInterval?

    public init(button: WristButton, range: ClosedRange<Double>) {
        self.button = button
        self.range = range
    }

    public mutating func started(at time: TimeInterval) {
        if startedAt == nil { startedAt = time }
    }

    /// The angle unclamped, so a caller can tell the limit from the angle.
    private func asked(at time: TimeInterval) -> Double {
        guard let startedAt else { return 0 }
        return button.degreesPerSecond * max(0, time - startedAt)
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
        return button.degreesPerSecond > 0 ? angle >= range.upperBound : angle <= range.lowerBound
    }
}
