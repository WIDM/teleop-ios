/// The operating screen's zones in points (§2.2), from the screen size and safe-area insets. Origin top left, y down.
/// The views should draw exactly these rectangles and the input rules hit-test exactly these, so a band cannot be
/// drawn in one place and judged in another.
public struct SurfaceLayout: Equatable, Sendable {
    public struct Rect: Equatable, Sendable {
        public var x, y, width, height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var maxX: Double { x + width }
        public var maxY: Double { y + height }
        public func contains(x px: Double, y py: Double) -> Bool { px >= x && px < maxX && py >= y && py < maxY }
    }

    public enum Zone: Equatable, Sendable { case bottomSafeArea, bottomBand, gap, gear, topBand, controlSurface }

    /// Scheme B halves, seen from the holding hand.
    public enum Side: Equatable, Sendable { case near, far, centre }

    public let width: Double
    public let height: Double
    /// Top of the screen to `safeTop + topBandExtraPt`.
    public let topBand: Rect
    /// The gear area at the top band's left end, below the status bar; it never starts the reset countdown. Never
    /// smaller than `gearMinPt` on a side.
    public let gear: Rect
    public let controlSurface: Rect
    /// Keeps a resting thumb off STOP; touches here do nothing.
    public let gap: Rect
    /// `bottomBandPt` high, full width, ending where the bottom safe area begins.
    public let bottomBand: Rect
    /// The bottom safe area under the band, where the home indicator is and the system's swipe home begins. A touch
    /// that begins here does nothing, so leaving the app never stops the robot. Zero high on a phone without one.
    public let bottomSafeArea: Rect
    public let pointsPerMm: Double
    public let edgeExclusionPt: Double
    public let sideDeadPt: Double

    /// `pointsPerMm` defaults to the reference device's. Zone sizes scale with the screen height (§2.2).
    public init(
        width: Double, height: Double, safeTop: Double, safeBottom: Double,
        pointsPerMm: Double? = nil, constants: InputConstants = .appendixA
    ) {
        let scale = height / constants.referenceHeightPt
        self.width = width
        self.height = height
        self.pointsPerMm = pointsPerMm ?? constants.referencePointsPerMm
        edgeExclusionPt = constants.edgeExclusionPt
        sideDeadPt = constants.sideDeadPt
        // The gear scales too, but never below its minimum, and the band always has room for it.
        let gearSide = max(constants.gearPt * scale, constants.gearMinPt)
        let topHeight = safeTop + max(constants.topBandExtraPt * scale, gearSide)
        let bandHeight = constants.bottomBandPt * scale
        let gapHeight = constants.gapPt * scale
        topBand = Rect(x: 0, y: 0, width: width, height: topHeight)
        gear = Rect(x: 0, y: safeTop + (topHeight - safeTop - gearSide) / 2, width: gearSide, height: gearSide)
        bottomSafeArea = Rect(x: 0, y: height - safeBottom, width: width, height: safeBottom)
        bottomBand = Rect(x: 0, y: bottomSafeArea.y - bandHeight, width: width, height: bandHeight)
        gap = Rect(x: 0, y: bottomBand.y - gapHeight, width: width, height: gapHeight)
        controlSurface = Rect(x: 0, y: topHeight, width: width, height: max(0, gap.y - topHeight))
    }

    /// §2.2's judging order, with the bottom safe area first: bottom band, gap, top band (the gear area first),
    /// control surface.
    public func zone(x: Double, y: Double) -> Zone {
        if bottomSafeArea.height > 0, y >= bottomSafeArea.y { return .bottomSafeArea }
        if y >= bottomBand.y { return .bottomBand }
        if y >= gap.y { return .gap }
        if y < topBand.maxY { return gear.contains(x: x, y: y) ? .gear : .topBand }
        return .controlSurface
    }

    /// The edge-grip filter: a touch that begins this close to the left or right edge is ignored.
    public func isAtSideEdge(x: Double) -> Bool { x <= edgeExclusionPt || x >= width - edgeExclusionPt }

    /// Scheme B: which half a touch-down is in for the holding hand. The band of ± `sideDeadPt` around the centre is
    /// neither.
    public func side(x: Double, hand: Hand) -> Side {
        let fromCentre = x - width / 2
        if abs(fromCentre) <= sideDeadPt { return .centre }
        return (fromCentre > 0) == (hand == .right) ? .near : .far
    }

    /// A distance on the glass in millimetres.
    public func millimetres(_ points: Double) -> Double { points / pointsPerMm }
}

/// Settings → Hand: which hand holds the phone. Scheme B closes the jaws on the half under its thumb.
public enum Hand: Equatable, Sendable { case right, left }
