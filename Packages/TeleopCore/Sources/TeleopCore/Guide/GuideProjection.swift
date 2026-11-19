import simd

/// Where a point of the robot's workspace goes in the guide's two views, and back. The guide places every mark through
/// one value of this, and a tap on the view from above is turned back into a place through the same value, so what is
/// drawn and what a tap asks for cannot disagree.
///
/// Points are in the operator's frame: metres right, forward and up as the operator sees them (`operatorPoint`).
/// Shares are fractions of a view's width and height, origin top left, y down, and are not clamped: where a mark
/// outside a view is drawn is the picture's business. Both views are equally wide and share one left-right axis and
/// one scale. From above, up is forward; from behind, up is up. The ranges are the work box plus a margin of
/// `marginShare` of its larger side, half that below the table.
public struct GuideProjection: Equatable, Sendable {
    /// Room around the workspace box, as a share of its larger side, so a mark on the box's edge is drawn whole.
    public static let marginShare = 0.15

    /// What the views span in the operator's frame, metres: right, forward (from above) and up (from behind).
    public let across: ClosedRange<Double>
    public let depth: ClosedRange<Double>
    public let height: ClosedRange<Double>

    /// `boxLow` and `boxHigh` are the work box in the operator's frame, corners sorted; `table` is the table's height,
    /// metres.
    public init(boxLow: SIMD3<Double>, boxHigh: SIMD3<Double>, table: Double, behindTop: Double? = nil) {
        let span = boxHigh - boxLow
        let margin = max(span.x, span.y) * Self.marginShare
        across = (boxLow.x - margin)...(boxHigh.x + margin)
        depth = (boxLow.y - margin)...(boxHigh.y + margin)
        let rearTop = behindTop.flatMap { $0.isFinite && $0 > table ? $0 : nil } ?? (max(boxHigh.z, table) + margin)
        height = (table - margin / 2)...rearTop
    }

    /// Width over height of the view from above, and of the view from behind.
    public var aboveAspect: Double { width / Self.length(depth) }
    public var behindAspect: Double { width / Self.length(height) }

    /// Right, forward and up as the operator sees them, metres, from a point in the robot base frame, by the axis table
    /// of `OperatorDirection`, the one source.
    public static func operatorPoint(_ base: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(
            simd_dot(base, OperatorDirection.right.baseVector),
            simd_dot(base, OperatorDirection.forward.baseVector),
            simd_dot(base, OperatorDirection.up.baseVector)
        )
    }

    /// The robot base frame point of an operator-frame point: the inverse of `operatorPoint`. The axis table is a
    /// signed permutation, so its inverse is its transpose.
    public static func base(fromOperator point: SIMD3<Double>) -> SIMD3<Double> {
        OperatorDirection.right.baseVector * point.x + OperatorDirection.forward.baseVector * point.y
            + OperatorDirection.up.baseVector * point.z
    }

    /// Where an operator-frame point sits in the view from above.
    public func above(_ point: SIMD3<Double>) -> SIMD2<Double> {
        SIMD2(Self.share(point.x, across), 1 - Self.share(point.y, depth))
    }

    /// Where an operator-frame point sits in the view from behind.
    public func behind(_ point: SIMD3<Double>) -> SIMD2<Double> {
        SIMD2(Self.share(point.x, across), 1 - Self.share(point.z, height))
    }

    /// The operator-frame point at `share` in the view from above, at height `up`, which that view does not show.
    public func point(aboveShare share: SIMD2<Double>, up: Double) -> SIMD3<Double> {
        SIMD3(across.lowerBound + share.x * width, depth.lowerBound + (1 - share.y) * Self.length(depth), up)
    }

    /// The operator-frame point at `share` in the rear view, with the supplied forward position.
    public func point(behindShare share: SIMD2<Double>, forward: Double) -> SIMD3<Double> {
        SIMD3(across.lowerBound + share.x * width, forward, height.lowerBound + (1 - share.y) * Self.length(height))
    }

    private var width: Double { Self.length(across) }

    private static func length(_ range: ClosedRange<Double>) -> Double { range.upperBound - range.lowerBound }

    private static func share(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }
}
