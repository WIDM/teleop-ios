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
///
/// The server clamps at the face itself, so a point pushed slowly out is clamped before it is past the slack. When the
/// server reports that clamp with the point past a watched face by any amount, that is the crossing: it is told at once
/// (the gap and each side's re-arm still hold) and the face itself is the edge until the point is back inside, so the
/// server need not tell it as well. A clamp with the point past no watched face is one this rule did not foresee.
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
    /// The server has clamped the point at a watched face in this hold, and the point has not been back inside every
    /// watched face since: until it is, past a face by any amount is outside.
    private var clampedAtFace = false

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
        let farthest = farthestPast(point)
        // Back inside every watched face: the clamp is over, and the slack counts again.
        if farthest.by <= 0 { clampedAtFace = false }
        outside = farthest.by > (clampedAtFace ? 0 : Self.slackMeters) ? farthest.side : nil
        return tellOutside(point, at: nowMs)
    }

    /// The server reports its clamp of this hold, with the gripper-link point the link is commanding now. `foreseen` is
    /// true when that point is past a watched face by any amount: the clamp is the crossing the rule watches for, its
    /// side is outside now and told at once unless the gap or that side's re-arm holds it back, and the server's own
    /// cue for the clamp would tell it twice. False, the point is past no watched face (a server whose box differs, or
    /// a face the rule does not watch): nothing changes, and the server's cue is the one that tells it. `told` is the
    /// side when the cue plays now.
    public mutating func serverClamped(
        _ point: SIMD3<Double>, at nowMs: Int
    ) -> (foreseen: Bool, told: OperatorDirection?) {
        guard hasBox else { return (false, nil) }
        let farthest = farthestPast(point)
        guard farthest.by > 0 else { return (false, nil) }
        clampedAtFace = true
        outside = farthest.side
        return (true, tellOutside(point, at: nowMs))
    }

    /// A new hold started: every side can be told again, and the slack counts until the server clamps.
    public mutating func holdStarted() {
        told = nil
        clampedAtFace = false
    }

    /// The watched side whose face `point` is farthest past, and by how much (negative: inside every watched face). At
    /// a corner the side the point is farthest beyond is named; an exact tie goes to the first in the table.
    private func farthestPast(_ point: SIMD3<Double>) -> (side: OperatorDirection, by: Double) {
        var farthest = (side: OperatorDirection.forward, by: -Double.infinity)
        for side in OperatorDirection.allCases where sides.contains(side) {
            let by = excess(of: point, past: side)
            if by > farthest.by { farthest = (side, by) }
        }
        return farthest
    }

    /// Plays the cue for `outside` unless that side is told and not armed again, or the last cue is too recent.
    private mutating func tellOutside(_ point: SIMD3<Double>, at nowMs: Int) -> OperatorDirection? {
        if let side = told, excess(of: point, past: side) <= -Self.rearmMeters { told = nil }
        guard let side = outside, side != told else { return nil }
        if let played = playedAtMs, nowMs - played < Self.minimumGapMs { return nil }
        told = side
        playedAtMs = nowMs
        return side
    }

    /// How far `point` lies past the box's face on `side`, metres: positive outside, negative inside.
    private func excess(of point: SIMD3<Double>, past side: OperatorDirection) -> Double {
        let way = side.baseVector
        return simd_dot(point, way) - max(simd_dot(low, way), simd_dot(high, way))
    }
}
