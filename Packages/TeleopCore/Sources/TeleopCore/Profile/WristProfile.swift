/// What the app has to know about one arm's wrist: how far a hold may turn or tilt it, which way the phone's turn and
/// tilt count on that arm, how fast the wrist buttons move it, and how far the commanded angle may run ahead of the
/// measured one. Two directions only: a turn (roll) and a tilt (flex). Angles are server degrees.
public struct WristProfile: Equatable, Sendable {
    /// Server wrist roll = `rollSign` × the turn, and server wrist flex = `tiltSign` × the tilt; 1 or -1. The turn is
    /// clockwise as the operator sees the screen (or the Turn right button); the tilt is the top of the phone away
    /// from the operator (or the Tilt down button). One pair for the phone and for the wrist buttons.
    public var rollSign: Double
    public var tiltSign: Double
    /// Roll stays within ± this of 0, judged from the measured roll.
    public var rollWindowDeg: Double
    /// Flex stays within ± this of the tilt window's centre.
    public var tiltWindowDeg: Double
    /// The most one hold may turn or tilt the wrist from where the hold began.
    public var rollClampDeg: Double
    public var tiltClampDeg: Double
    /// Where the tilt window is centred.
    public var tiltCentre: TiltCentre
    /// How fast the wrist buttons move the wrist, degrees a second, whichever way.
    public var turnRateDegS: Double
    public var tiltRateDegS: Double
    /// How far the commanded angle may run ahead of the measured one.
    public var lead: WristLeadLimits

    public init(
        rollSign: Double, tiltSign: Double, rollWindowDeg: Double, tiltWindowDeg: Double, rollClampDeg: Double,
        tiltClampDeg: Double, tiltCentre: TiltCentre, turnRateDegS: Double, tiltRateDegS: Double,
        lead: WristLeadLimits
    ) {
        self.rollSign = rollSign
        self.tiltSign = tiltSign
        self.rollWindowDeg = rollWindowDeg
        self.tiltWindowDeg = tiltWindowDeg
        self.rollClampDeg = rollClampDeg
        self.tiltClampDeg = tiltClampDeg
        self.tiltCentre = tiltCentre
        self.turnRateDegS = turnRateDegS
        self.tiltRateDegS = tiltRateDegS
        self.lead = lead
    }

    /// The flex the tilt window is centred on: the profile's number, or the flex measured after the last reset
    /// (`measuredAfterReset`) when the profile says so. Nil while that is not known.
    public func tiltCentreDeg(measuredAfterReset: Double?) -> Double? {
        switch tiltCentre {
        case .measuredAfterReset: return measuredAfterReset
        case .fixed(let degrees): return degrees
        }
    }
}

/// Where the tilt window is centred.
public enum TiltCentre: Hashable, Sendable {
    /// On the flex measured in the first state after the last reset: the arm's neutral wrist is where a reset leaves it.
    case measuredAfterReset
    /// On this flex, degrees: the arm's neutral wrist is a known pose that a reset does not decide.
    case fixed(Double)
}

/// The numbers of the wrist lead bound (`WristLeadBound`): the commanded wrist angle never leads the newest fresh
/// measured angle by more than `leadDeg` plus `rateMaxDegS` times that angle's age.
public struct WristLeadLimits: Equatable, Sendable {
    /// The lead always allowed, degrees.
    public var leadDeg: Double
    /// How fast the allowed lead grows with the age of the measurement, degrees a second. Not a speed limit of the
    /// wrist.
    public var rateMaxDegS: Double
    /// A remembered lead counts for the next hold only while the wrist has moved no more than this since, degrees.
    public var memoryDeg: Double
    /// A measurement older than this is not fresh, milliseconds.
    public var freshStateMs: Int

    public init(leadDeg: Double, rateMaxDegS: Double, memoryDeg: Double, freshStateMs: Int) {
        self.leadDeg = leadDeg
        self.rateMaxDegS = rateMaxDegS
        self.memoryDeg = memoryDeg
        self.freshStateMs = freshStateMs
    }
}
