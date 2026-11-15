import simd

/// Tells, every time, that the place the operator is commanding has left the work area, and on which side. Pure: time
/// is passed in, in milliseconds, like `OnTargetCue`.
///
/// It judges in gripper-link space: the commanded gripper-link point against the profile's box minus its tool offset.
/// The server keeps the gripper link in its box, and the guide draws the commanded ring and the box with the same
/// measured offset added to both, so this is the judgement the picture shows. A point beyond a face by more than
/// `slackMeters` is outside, on the side whose face it is farthest beyond, named through the axis table of
/// `OperatorDirection`.
///
/// The cue plays on the tick that turns inside into outside, and again when the side changes while outside. Once a side
/// has been told, it is told again only after the point has come back inside that side's face by `rearmMeters`, or a
/// new hold has started, so a point resting on a face is told once. Two cues are never closer than `minimumGapMs`, so a
/// point hovering at the edge does not chatter; a cue held back by that gap plays on the first tick after it if the
/// point is still out on a side not yet told.
///
/// Only the faces of the sides it watches count. A face the arm is stopped before, such as a floor below the table, is
/// left out by whoever builds the rule: something else already tells that stop, and one act should get one cue.
public struct WorkAreaCue: Sendable {
    /// Beyond a face by more than this counts as outside: the guide's own millimetre plus rounding.
    public static let slackMeters = 0.002
    /// Back inside a face by this much before that side can be told again.
    public static let rearmMeters = 0.005
    /// Never two cues closer together than this.
    public static let minimumGapMs = 1500

    /// The box in gripper-link space, robot base frame, metres.
    public let low: SIMD3<Double>
    public let high: SIMD3<Double>
    /// The sides whose faces count. A point past any other face is judged as if that face were not there.
    public let sides: Set<OperatorDirection>
    /// The side the commanded point is outside on now, for the guide's line; nil while inside. The line and the cue
    /// read this one value, so they cannot disagree.
    public private(set) var outside: OperatorDirection?
    /// A box with a number that is not finite has no faces the arm can be asked past, so nothing is ever outside it.
    private let hasBox: Bool
    /// The side last told and not yet armed again; nil while armed.
    private var told: OperatorDirection?
    private var playedAtMs: Int?

    /// `low` and `high` are opposite corners of the box in gripper-link space, robot base frame; either order.
    /// `sides`: the faces that count; all six unless a face cannot be reached.
    public init(
        low: SIMD3<Double>, high: SIMD3<Double>, sides: Set<OperatorDirection> = Set(OperatorDirection.allCases)
    ) {
        self.low = simd_min(low, high)
        self.high = simd_max(low, high)
        self.sides = sides
        hasBox = [low.x, low.y, low.z, high.x, high.y, high.z].allSatisfy(\.isFinite)
    }

    /// One tick of a translation hold, with the gripper-link point the link is commanding. Returns the side when the cue
    /// plays now.
    public mutating func commanded(_ point: SIMD3<Double>, at nowMs: Int) -> OperatorDirection? {
        guard hasBox else { return nil }
        // At a corner the side the point is farthest beyond is named; an exact tie goes to the first in the table.
        var farthest = (side: OperatorDirection.forward, by: -Double.infinity)
        for side in OperatorDirection.allCases where sides.contains(side) {
            let by = excess(of: point, past: side)
            if by > farthest.by { farthest = (side, by) }
        }
        outside = farthest.by > Self.slackMeters ? farthest.side : nil
        if let side = told, excess(of: point, past: side) <= -Self.rearmMeters { told = nil }
        guard let side = outside, side != told else { return nil }
        if let played = playedAtMs, nowMs - played < Self.minimumGapMs { return nil }
        told = side
        playedAtMs = nowMs
        return side
    }

    /// A new hold started: every side can be told again.
    public mutating func holdStarted() { told = nil }

    /// How far `point` lies past the box's face on `side`, metres: positive outside, negative inside.
    private func excess(of point: SIMD3<Double>, past side: OperatorDirection) -> Double {
        let way = side.baseVector
        return simd_dot(point, way) - max(simd_dot(low, way), simd_dot(high, way))
    }
}
