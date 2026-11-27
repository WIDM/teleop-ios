/// What a jaw reading is measured in.
public enum JawUnit: String, Equatable, Sendable, CaseIterable {
    /// Degrees of a hinged jaw.
    case deg
    /// Millimetres between parallel jaws.
    case mm

    /// The unit's short name as the app writes it after a number.
    public var symbol: String { rawValue }

    /// The units a file may name, as the errors write them.
    public static var allowedText: String { "\"deg\" or \"mm\"" }
}

/// What the app has to know about one arm's gripper: what its readings mean. The server's message field is called
/// `gripper_deg` whatever the unit; it carries the jaw reading in `unit`.
public struct GripperProfile: Equatable, Sendable {
    public var unit: JawUnit
    /// The two readings the opening share is drawn between: the reading with the jaws shut and the one with them
    /// open as far as they go. Different numbers.
    public var closedReading: Double
    public var openReading: Double
    /// The readings that count as a jaw reading at all; a number outside is dropped as if the server had not sent it.
    public var validMin: Double
    public var validMax: Double
    /// A reading at or above this while opening is fully open.
    public var fullyOpenAt: Double
    /// A reading at or below this when a close has ended with no contact: the jaws closed on nothing.
    public var emptyAt: Double

    public init(
        unit: JawUnit, closedReading: Double, openReading: Double, validMin: Double, validMax: Double,
        fullyOpenAt: Double, emptyAt: Double
    ) {
        self.unit = unit
        self.closedReading = closedReading
        self.openReading = openReading
        self.validMin = validMin
        self.validMax = validMax
        self.fullyOpenAt = fullyOpenAt
        self.emptyAt = emptyAt
    }

    /// The readings that count, as a range. Only for a profile that has passed `validate()`, which makes sure the
    /// two ends are in order.
    public var validReadings: ClosedRange<Double> { validMin...validMax }

    /// How open the jaws are at `reading`, 0 shut to 1 open, held to that range.
    public func opening(at reading: Double) -> Double {
        min(max((reading - closedReading) / (openReading - closedReading), 0), 1)
    }

    /// The two thresholds the feedback rules read.
    public var limits: GripperLimits { GripperLimits(fullyOpenAt: fullyOpenAt, emptyAt: emptyAt) }

    /// `reading` written with its unit, such as `97 deg` or `40 mm`.
    public func text(_ reading: Double) -> String {
        let rounded = (reading * 10).rounded() / 10
        let number = rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
        return "\(number) \(unit.symbol)"
    }
}
