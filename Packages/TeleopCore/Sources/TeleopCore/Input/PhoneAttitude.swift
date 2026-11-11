import simd

/// The phone's attitude as a unit quaternion in portrait device axes (I-8.1): x toward the screen's right edge, y toward
/// its top edge, z out of the screen toward the operator. Only rotations relative to an anchor are used, so the world
/// frame is whatever ARKit's is.
public enum PhoneAttitude {
    /// ARKit's camera axes are fixed to the device: x runs along the long side from the front camera toward the
    /// bottom edge, y toward the portrait right edge, z out of the screen. Portrait x is camera y and portrait y is
    /// camera −x: a quarter turn about z.
    static let cameraToPortrait = simd_quatd(angle: .pi / 2, axis: SIMD3(0, 0, 1))

    /// The attitude in portrait device axes from `ARFrame.camera.transform`.
    public static func portrait(cameraTransform t: simd_float4x4) -> simd_quatd {
        let column = { (c: SIMD4<Float>) in SIMD3<Double>(Double(c.x), Double(c.y), Double(c.z)) }
        let rotation = simd_double3x3(column(t.columns.0), column(t.columns.1), column(t.columns.2))
        return portrait(camera: simd_quatd(rotation))
    }

    /// The attitude in portrait device axes from the camera's orientation in the world.
    public static func portrait(camera: simd_quatd) -> simd_quatd {
        simd_normalize(camera * cameraToPortrait)
    }
}

/// How far the phone has turned and tilted from an anchor attitude, by a swing-twist split of the relative rotation
/// (I-8.1). Rotation about the phone's y axis is ignored.
public struct WristAngles: Equatable, Sendable {
    /// The steering-wheel motion, degrees: positive is clockwise as the operator sees the screen.
    public var turn: Double
    /// Tipping the phone, degrees: positive is the top edge away from the operator.
    public var tilt: Double

    public init(turn: Double, tilt: Double) {
        self.turn = turn
        self.tilt = tilt
    }

    public static let zero = WristAngles(turn: 0, tilt: 0)

    /// `R_rel = R_anchor⁻¹ · R_now` split as swing · twist: the twist about z is the turn and the swing's part about x
    /// is the tilt. Both attitudes are in portrait device axes.
    public init(from anchor: simd_quatd, to now: simd_quatd) {
        let relative = Self.positive(simd_normalize(anchor.inverse * now))
        let twistAngle = 2 * atan2(relative.imag.z, relative.real)
        let twist = simd_quatd(angle: twistAngle, axis: SIMD3(0, 0, 1))
        let swing = Self.positive(relative * twist.inverse)
        let swingAboutX = 2 * atan2(swing.imag.x, swing.real)
        // A positive rotation about z is counterclockwise seen from the operator, and a positive rotation about x
        // brings the top edge toward the operator; the operator's words are the other way round.
        turn = -twistAngle * 180 / .pi
        tilt = -swingAboutX * 180 / .pi
    }

    /// The same rotation with a non-negative real part, so half-angles stay within ±90°.
    private static func positive(_ q: simd_quatd) -> simd_quatd { q.real < 0 ? simd_quatd(vector: -q.vector) : q }
}
