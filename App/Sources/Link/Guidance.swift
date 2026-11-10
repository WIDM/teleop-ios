import simd
import TeleopCore

/// Where the thing to reach is, as the operator sees it, so the task does not have to be done by eye alone.
struct Guidance: Equatable {
    enum Target: Equatable { case cube, goal, done }

    var target: Target
    /// Metres right, forward and up from the gripper to the target. The server reports the gripper link's
    /// origin, not the fingertips, so "up" is to the cube's centre from a point above the jaws.
    var offset: SIMD3<Float>
    /// The arm stopped following in the direction it is being asked to go: it is at the edge of its range.
    var atEdge = false

    /// How close, flat on the table, the gripper must be to the cube to count as holding it once closed.
    static let holdingRadius: Float = 0.03
    /// Half-size of the goal area on the table, as the server judges success.
    static let goalHalfExtent: Float = 0.025

    /// All positions in the robot base frame, metres.
    static func make(arm: SIMD3<Float>, cube: SIMD3<Float>, goal: SIMD3<Float>, gripper: GripperState?) -> Guidance {
        let cubeToGoal = goal - cube
        if abs(cubeToGoal.x) <= goalHalfExtent, abs(cubeToGoal.y) <= goalHalfExtent {
            return Guidance(target: .done, offset: .zero)
        }
        let flat = SIMD2(cube.x - arm.x, cube.y - arm.y)
        let holding = gripper == .closed && simd_length(flat) <= holdingRadius
        // Carrying: steer the cube, which moves with the gripper, to the goal. Otherwise steer the gripper to the cube.
        let base = holding ? cubeToGoal : cube - arm
        return Guidance(target: holding ? .goal : .cube, offset: operatorOffset(base))
    }

    /// Robot base to operator directions. The server maps right → −X, forward → −Y, up → +Z.
    static func operatorOffset(_ base: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(-base.x, -base.y, base.z)
    }
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
    /// Once tilted, the phone must come back this much inside a limit to count as upright again,
    /// so a hand hovering at the limit does not flicker (and buzz) back and forth.
    static let returnMarginDegrees: Float = 10

    static func of(_ camera: simd_float4x4?, previous: PhonePosture = .unknown) -> PhonePosture {
        guard let camera else { return .unknown }
        let axes = PhoneAxes(camera)
        let margin = previous == .tilted ? returnMarginDegrees : 0
        let sideways = abs(axes.right.y) > sin((sidewaysDegrees - margin) * .pi / 180)
        let faceDown = axes.view.y > sin((faceDownDegrees - margin) * .pi / 180)
        let upsideDown = axes.top.y < (previous == .tilted ? -0.15 : -0.3)
        return sideways || faceDown || upsideDown ? .tilted : .upright
    }
}
