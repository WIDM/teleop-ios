/// The six ways the operator can send the arm, as seen from the operator's place at the table. Buttons, voice and
/// the phone all use this frame (INTERACTION §3.3).
public enum OperatorDirection: String, CaseIterable, Sendable {
    case forward, back, left, right, up, down

    /// §3.3's axis table: the robot base axis this direction moves the arm along, and which way.
    /// This table is the one source; every other frame is derived from it.
    public var baseAxis: (axis: BaseAxis, sign: Double) {
        switch self {
        case .forward: return (.y, -1)
        case .back: return (.y, +1)
        case .left: return (.x, +1) // toward the goal
        case .right: return (.x, -1)
        case .up: return (.z, +1)
        case .down: return (.z, -1)
        }
    }

    /// One metre this way, in the robot base frame.
    public var baseVector: SIMD3<Double> {
        let (axis, sign) = baseAxis
        switch axis {
        case .x: return SIMD3(sign, 0, 0)
        case .y: return SIMD3(0, sign, 0)
        case .z: return SIMD3(0, 0, sign)
        }
    }

    /// One metre this way, in the frame `TeleopLink.poseUpdate(positionMeters:)` takes.
    public var linkVector: SIMD3<Double> { OperatorFrame.link(fromBase: baseVector) }
}

public enum BaseAxis: String, Sendable { case x, y, z }

/// Converts between the operator's frame, the robot base frame and the frame the link's translation hold is sent in.
public enum OperatorFrame {
    /// Metres right, forward and up as the operator sees them, as an offset for the link's translation hold.
    /// The phone's motion and the buttons' ramps both end up here.
    public static func linkOffset(right: Double, forward: Double, up: Double) -> SIMD3<Double> {
        OperatorDirection.right.linkVector * right
            + OperatorDirection.forward.linkVector * forward
            + OperatorDirection.up.linkVector * up
    }

    /// The server was calibrated on a WebXR phone (mapping `phone_axes_20261025_v1`): it moves the arm by
    /// [p0, p1, −p2] of the offset it is sent.
    public static func base(fromLink p: SIMD3<Double>) -> SIMD3<Double> { SIMD3(p.x, p.y, -p.z) }

    public static func link(fromBase b: SIMD3<Double>) -> SIMD3<Double> { SIMD3(b.x, b.y, -b.z) }
}
