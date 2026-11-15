import simd

/// The guide's view from above as it is drawn now: its rectangle on the glass, the projection it was drawn with, and the
/// work box and table it shows. The rectangle is the frame the view reported; nothing recomputes it, so a tap is judged
/// against what the operator sees. A touch keeps the panel of its touch-down, so one tap is judged against one
/// rectangle and one projection.
public struct GoPanel: Equatable, Sendable {
    /// Operating-screen points, origin top left: the coordinates touches arrive in.
    public var rect: SurfaceLayout.Rect
    public var projection: GuideProjection
    /// The work box as drawn: the profile's box moved by the reading's `boxShift` (its measured gripper-to-pinch offset
    /// less the profile's tool offset, zero unless the server reports a tool point), robot base frame, pinch point,
    /// metres, corners sorted.
    public var boxLow: SIMD3<Double>
    public var boxHigh: SIMD3<Double>
    /// The table's height, robot base frame, metres.
    public var tableHeight: Double

    public init(
        rect: SurfaceLayout.Rect, projection: GuideProjection, boxLow: SIMD3<Double>, boxHigh: SIMD3<Double>,
        tableHeight: Double
    ) {
        self.rect = rect
        self.projection = projection
        self.boxLow = boxLow
        self.boxHigh = boxHigh
        self.tableHeight = tableHeight
    }

    public func contains(x: Double, y: Double) -> Bool { rect.contains(x: x, y: y) }

    /// The pinch-point place a tap at (x, y) asks for, robot base frame: the point the view from above draws there, at
    /// `travelHeight` above the table. Not checked against the box; `inBox` does that.
    public func target(x: Double, y: Double, travelHeight: Double) -> SIMD3<Double> {
        let share = SIMD2((x - rect.x) / rect.width, (y - rect.y) / rect.height)
        let up = tableHeight + travelHeight
        return GuideProjection.base(fromOperator: projection.point(aboveShare: share, up: up))
    }

    /// Inside the work box as drawn, on all three axes, with no slack: the guide counts a reading a millimetre outside
    /// as inside so that it does not flicker, but a place the arm is sent to must lie in the box itself.
    public func inBox(_ point: SIMD3<Double>) -> Bool {
        all(point .>= boxLow) && all(point .<= boxHigh)
    }

    /// Where on the glass the view from above draws `base`, a robot base frame point (its height does not matter
    /// there): the forward projection, for tests and scripted hands that write their taps in metres.
    public func point(over base: SIMD3<Double>) -> SIMD2<Double> {
        let share = projection.above(GuideProjection.operatorPoint(base))
        return SIMD2(rect.x + share.x * rect.width, rect.y + share.y * rect.height)
    }
}

/// The measured arm, as the input rules are told it while tap-to-go is allowed.
public struct ArmFix: Equatable, Sendable {
    /// The measured pinch point of the newest state that carried a position, robot base frame, metres.
    public var pinch: SIMD3<Double>
    /// How old that state is, seconds. A state without a position never makes a fix fresh.
    public var ageS: Double
    /// The link is re-sending its start, or holding a start back behind a finishing hold: the arm may stand still for
    /// a reason that says nothing about where it can go.
    public var holdPaused: Bool

    public init(pinch: SIMD3<Double>, ageS: Double, holdPaused: Bool) {
        self.pinch = pinch
        self.ageS = ageS
        self.holdPaused = holdPaused
    }
}
