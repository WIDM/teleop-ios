/// Every threshold the input rules use, under the names of the interaction specification's Appendix A, so each
/// value has one source and can be written whole into a log header. Times keep the appendix's units: a name ending
/// in `Ms` is milliseconds, one ending in `S` is seconds.
public struct InputConstants: Equatable, Sendable {
    // Wrist (I-8.2, I-8.3)
    public var rollClampDeg: Double
    public var tiltClampDeg: Double
    /// Roll stays within ± this, judged from the measured `wrist_roll_deg` (server soft limit ±160).
    public var rollWindowDeg: Double
    /// Flex stays within ± this of the flex measured after the last reset.
    public var tiltWindowDeg: Double
    public var axisLockDeg: Double
    public var axisLockRatio: Double
    /// Server roll = `rollSign` × turn, server flex = `tiltSign` × tilt (turn: clockwise as the operator sees the
    /// screen; tilt: top of the phone away from the operator). Robot numbers, fixed once by the live mapping check
    /// C-I5; the owner of the robot profile passes them in.
    public var rollSign: Double
    public var tiltSign: Double
    /// Exponential smoothing of the wrist angle: the share of the previous value kept per 1/30 s.
    public var angleSmoothing: Double
    /// After a limit, END plays again only once the angle has backed off this far from the edge (I-8.3).
    /// The appendix gives the value in the text of I-8.3 but no name.
    public var limitRearmDeg: Double

    // Touches (§2.2, A-4, A-5, B-3)
    public var palmRadiusPt: Double
    public var palmWindowMs: Double
    public var edgeExclusionPt: Double
    public var openSlideMm: Double
    public var sideDeadPt: Double
    public var gripDwellMs: Double
    public var openWhileGrippingMs: Double

    // Zones (§2.2): sizes on the reference device, scaled with screen height.
    public var bottomBandPt: Double
    public var gapPt: Double
    public var topBandExtraPt: Double
    public var gearPt: Double
    /// The gear area is never smaller than this, however short the screen: the smallest comfortable touch target.
    public var gearMinPt: Double
    public var gearTapS: Double
    /// The reference device's height, which the zone sizes are given for.
    public var referenceHeightPt: Double
    /// 10 mm is 64 pt on the reference device. A device that knows its own density passes it to `SurfaceLayout`.
    public var referencePointsPerMm: Double

    // Keys (I-2.4)
    public var keyChordMs: Double
    public var keyReplayMs: Double
    /// Device check 2: whether the platform delivers a key that was pressed while the other was held, at the other's
    /// release. While true, a key that begins within `keyReplayMs` of the other key's release is dead.
    public var keyReplayGuard: Bool

    // Reset (I-3)
    public var resetHoldS: Double

    public init(
        rollClampDeg: Double = 55, tiltClampDeg: Double = 20,
        rollWindowDeg: Double = 150, tiltWindowDeg: Double = 25,
        axisLockDeg: Double = 5, axisLockRatio: Double = 0.6,
        rollSign: Double = 1, tiltSign: Double = 1,
        angleSmoothing: Double = 0.2, limitRearmDeg: Double = 5,
        palmRadiusPt: Double = 32, palmWindowMs: Double = 100, edgeExclusionPt: Double = 12,
        openSlideMm: Double = 10, sideDeadPt: Double = 24,
        gripDwellMs: Double = 150, openWhileGrippingMs: Double = 500,
        bottomBandPt: Double = 72, gapPt: Double = 16, topBandExtraPt: Double = 64, gearPt: Double = 56,
        gearMinPt: Double = 44, gearTapS: Double = 0.5, referenceHeightPt: Double = 874, referencePointsPerMm: Double = 6.4,
        keyChordMs: Double = 50, keyReplayMs: Double = 150, keyReplayGuard: Bool = true,
        resetHoldS: Double = 2.0
    ) {
        self.rollClampDeg = rollClampDeg
        self.tiltClampDeg = tiltClampDeg
        self.rollWindowDeg = rollWindowDeg
        self.tiltWindowDeg = tiltWindowDeg
        self.axisLockDeg = axisLockDeg
        self.axisLockRatio = axisLockRatio
        self.rollSign = rollSign
        self.tiltSign = tiltSign
        self.angleSmoothing = angleSmoothing
        self.limitRearmDeg = limitRearmDeg
        self.palmRadiusPt = palmRadiusPt
        self.palmWindowMs = palmWindowMs
        self.edgeExclusionPt = edgeExclusionPt
        self.openSlideMm = openSlideMm
        self.sideDeadPt = sideDeadPt
        self.gripDwellMs = gripDwellMs
        self.openWhileGrippingMs = openWhileGrippingMs
        self.bottomBandPt = bottomBandPt
        self.gapPt = gapPt
        self.topBandExtraPt = topBandExtraPt
        self.gearPt = gearPt
        self.gearMinPt = gearMinPt
        self.gearTapS = gearTapS
        self.referenceHeightPt = referenceHeightPt
        self.referencePointsPerMm = referencePointsPerMm
        self.keyChordMs = keyChordMs
        self.keyReplayMs = keyReplayMs
        self.keyReplayGuard = keyReplayGuard
        self.resetHoldS = resetHoldS
    }

    /// Appendix A as written. `rollSign` and `tiltSign` are +1 until C-I5 measures them.
    public static let appendixA = InputConstants()
}
