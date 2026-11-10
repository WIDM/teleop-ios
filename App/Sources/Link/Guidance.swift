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

/// Whether the phone is held the way the direction mapping is easiest to follow: upright, screen to the operator.
enum PhonePosture: Equatable {
    case upright
    /// Lying back, face down, or turned on its side.
    case tilted
    /// ARKit has no pose yet.
    case unknown

    /// Upright within this many degrees: the top edge points at the ceiling.
    static let toleranceDegrees: Float = 35

    static func of(_ camera: simd_float4x4?) -> PhonePosture {
        guard let camera else { return .unknown }
        // Column 1 is the direction of the phone's top edge in the world; world up is +y.
        let top = simd_normalize(SIMD3(camera.columns.1.x, camera.columns.1.y, camera.columns.1.z))
        return top.y >= cos(toleranceDegrees * .pi / 180) ? .upright : .tilted
    }
}
