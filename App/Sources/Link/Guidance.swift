import simd
import TeleopCore

/// The profile's helpers that need the app's own types. The profile itself comes from `ProfileLoader`.
extension RobotProfile {
    /// Where the jaws pinch, robot base frame: the server's tool point when it reports one, else the reported gripper
    /// point plus `toolOffset`, judged by `estimateIsApproximate`. Everything that draws the pinch point gets it here.
    /// A tool point that cannot be moved to as a `Float` (either point beyond its range) counts as not reported: the
    /// guide's box moves by the offset, and an infinite one would leave it no size.
    func pinchPoint(gripper: SIMD3<Float>, tool: SIMD3<Float>?, flexDeg: Double?, rollDeg: Double?) -> PinchPoint {
        guard let tool, case let offset = tool - gripper, [offset.x, offset.y, offset.z].allSatisfy(\.isFinite) else {
            let approximate = estimateIsApproximate(gripper: gripper, flexDeg: flexDeg, rollDeg: rollDeg)
            return PinchPoint(
                point: gripper + toolOffset, source: .estimated(approximate: approximate), offset: toolOffset)
        }
        return PinchPoint(point: tool, source: .reported, offset: offset)
    }
}

/// Where the pinch point of one reading came from.
enum PinchSource: Equatable, Sendable {
    /// The server reported it (`tool_pos`). Never approximate.
    case reported
    /// The reported gripper point plus the profile's `toolOffset`. `approximate`: it may be off by more than half the
    /// grasp tolerance, so the guide draws it hollow, says so, and never says "On target".
    case estimated(approximate: Bool)

    var isApproximate: Bool { self == .estimated(approximate: true) }
}

/// The pinch point of one reading, and how to move a gripper-link point there.
struct PinchPoint: Equatable, Sendable {
    var point: SIMD3<Float>
    var source: PinchSource
    /// From the gripper link origin to the pinch point: `tool_pos − ee_pos` of the same reading when the server reports
    /// a tool point, else `toolOffset`. The server's command and workspace box are for the gripper link, so the guide
    /// moves them by this to draw them for the pinch point. A measured offset is exact only while the wrist keeps its
    /// pose: the next tilt or turn moves the jaws around the gripper link.
    var offset: SIMD3<Float>
}

/// The phone's own directions in the world, for a phone held in portrait.
/// ARKit's camera axes are fixed to the sensor, which sits landscape: +x runs along the long edge toward the
/// bottom of a portrait phone, +y toward its right edge, +z out of the screen.
struct PhoneAxes {
    let right: SIMD3<Float>
    let top: SIMD3<Float>
    /// Where the back camera looks.
    let view: SIMD3<Float>

    init(_ camera: simd_float4x4) {
        right = simd_normalize(SIMD3(camera.columns.1.x, camera.columns.1.y, camera.columns.1.z))
        top = -simd_normalize(SIMD3(camera.columns.0.x, camera.columns.0.y, camera.columns.0.z))
        view = -simd_normalize(SIMD3(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z))
    }
}

/// Whether the phone is held so that right, forward and up mean what the operator expects.
/// Leaning back is fine, all the way to lying flat with the screen up: the direction mapping covers that.
/// What breaks it is holding the phone sideways, or with the screen turned toward the floor.
enum PhonePosture: Equatable {
    case upright
    /// Sideways, screen toward the floor, or upside down.
    case tilted
    /// ARKit has no pose yet.
    case unknown

    /// The side edge may dip this far from level before it counts as sideways.
    static let sidewaysDegrees: Float = 40
    /// The back camera may point this far above level before the screen counts as facing the floor.
    static let faceDownDegrees: Float = 30

    /// Judged once, at the press of a translation.
    static func of(_ camera: simd_float4x4?) -> PhonePosture {
        guard let camera else { return .unknown }
        let axes = PhoneAxes(camera)
        let sideways = abs(axes.right.y) > sin(sidewaysDegrees * .pi / 180)
        let faceDown = axes.view.y > sin(faceDownDegrees * .pi / 180)
        let upsideDown = axes.top.y < -0.3
        return sideways || faceDown || upsideDown ? .tilted : .upright
    }
}
