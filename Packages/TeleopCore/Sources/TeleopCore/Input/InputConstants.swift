/// Every threshold the input rules use, under the names of the interaction specification's Appendix A, so each
/// value has one source and can be written whole into a log header. Times keep the appendix's units: a name ending
/// in `Ms` is milliseconds, one ending in `S` is seconds.
public struct InputConstants: Equatable, Sendable {
    // Wrist (I-8.2, I-8.3): the arm's own numbers, from its profile and nowhere else.
    public var wrist: WristProfile
    public var rollClampDeg: Double { wrist.rollClampDeg }
    public var tiltClampDeg: Double { wrist.tiltClampDeg }
    /// Roll stays within ± this, judged from the measured `wrist_roll_deg`.
    public var rollWindowDeg: Double { wrist.rollWindowDeg }
    /// Flex stays within ± this of the tilt window's centre (`WristProfile.tiltCentre`).
    public var tiltWindowDeg: Double { wrist.tiltWindowDeg }
    /// Server roll = `rollSign` × turn, server flex = `tiltSign` × tilt (turn: clockwise as the operator sees the
    /// screen; tilt: top of the phone away from the operator).
    public var rollSign: Double { wrist.rollSign }
    public var tiltSign: Double { wrist.tiltSign }
    public var axisLockDeg: Double
    public var axisLockRatio: Double
    /// Exponential smoothing of the wrist angle: the share of the previous value kept per 1/30 s.
    public var angleSmoothing: Double
    /// After a limit, END plays again only once the angle has backed off this far from the edge (I-8.3).
    /// The appendix gives the value in the text of I-8.3 but no name.
    public var limitRearmDeg: Double

    // Touches (§2.2, A-4, A-5, B-3)
    /// A contact this wide at touch-down, or growing this wide inside `palmWindowMs`, is a palm and is ignored,
    /// except on the STOP band, where every touch stops the robot.
    /// Measured on an iPhone 17, which reports the radius in steps of about 12 pt: a thumb pad pressed, held or slid
    /// was at most 85 pt wide inside the window (most were 36 to 61), a tap 24 to 61, and the base of the hand
    /// pressed on the glass 97 pt or more. 91 pt is a contact about 30 mm across.
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

    // Thumb gestures of the aids. Not in Appendix A; kept here so every input threshold has one source.

    /// A thumb sliding toward a lock is under way once it has gone this far up the glass while mostly up, millimetres.
    /// From then on a NO it owes waits until it latches, lifts or turns away. Evidence that would change it: hand
    /// traces of the gesture.
    public var slideUnderWayMm: Double
    /// A touch that began inside the guide's view from above is a tap only if it lifts within this, seconds. In scheme
    /// B the dwell (150 ms; 500 ms on the far half while gripping) comes first and keeps its 1.0.1 meaning. Evidence
    /// that would change it: durations of intended and unintended taps logged on the device.
    public var tapMaxS: Double
    /// ... and only if it never went farther than this from its touch-down, straight distance, millimetres. Well under
    /// the 10 mm that commits a slide. Evidence: tap travel
    /// logged on the device.
    public var tapSlopMm: Double
    /// Longest lift that can still be explained as a missed tap. Evidence: the duration of intended taps.
    public static let tapSaysWhyMaxS: Double = 1
    /// Longest gap between a tap's lift and a second contact that may be a bounce. Evidence: gaps between contacts.
    public static let secondContactS: Double = 0.15

    /// The wrist has no default: its numbers belong to one arm and come from that arm's profile.
    public init(
        wrist: WristProfile,
        axisLockDeg: Double = 5, axisLockRatio: Double = 0.6,
        angleSmoothing: Double = 0.2, limitRearmDeg: Double = 5,
        palmRadiusPt: Double = 91, palmWindowMs: Double = 100, edgeExclusionPt: Double = 12,
        openSlideMm: Double = 10, sideDeadPt: Double = 24,
        gripDwellMs: Double = 150, openWhileGrippingMs: Double = 500,
        bottomBandPt: Double = 72, gapPt: Double = 16, topBandExtraPt: Double = 64, gearPt: Double = 56,
        gearMinPt: Double = 44, gearTapS: Double = 0.5, referenceHeightPt: Double = 874,
        referencePointsPerMm: Double = 6.4,
        keyChordMs: Double = 50, keyReplayMs: Double = 150, keyReplayGuard: Bool = true,
        resetHoldS: Double = 2.0, slideUnderWayMm: Double = 3, tapMaxS: Double = 0.30, tapSlopMm: Double = 4
    ) {
        self.wrist = wrist
        self.axisLockDeg = axisLockDeg
        self.axisLockRatio = axisLockRatio
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
        self.slideUnderWayMm = slideUnderWayMm
        self.tapMaxS = tapMaxS
        self.tapSlopMm = tapSlopMm
    }
}
