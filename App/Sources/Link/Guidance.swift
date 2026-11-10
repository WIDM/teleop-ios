import simd
import TeleopCore

/// What the app has to know about one robot setup to put the arm and the things around it in one picture.
/// The server's state does not carry these, so each setup the app drives needs a profile.
struct RobotProfile: Equatable {
    var name: String
    /// From the point the server reports for the arm (the gripper link origin) to where the jaws pinch,
    /// in the robot base frame, metres. Holds while the wrist joints stay put, as in translation mode.
    var toolOffset: SIMD3<Float>
    /// Where the robot base sits in the world frame, metres. The server reports the arm in the base frame
    /// and objects in the world frame; this brings objects into the base frame.
    var baseInWorld: SIMD3<Float>

    /// The SO-101 in the S4 pick-and-place simulator. The tool offset was measured there on 2026-11-11 by
    /// grasping the cube: 6.6 cm ahead of the reported point (−Y) and 8.65 cm below it. The robot's USD model
    /// predicts 5.8 cm and 8.9 cm. The base height is ROBOT_BASE_POS_W in the simulator's source.
    static let so101Simulator = RobotProfile(
        name: "SO-101 (S4 simulator)",
        toolOffset: SIMD3(0, -0.066, -0.0865),
        baseInWorld: SIMD3(0, 0, 0.05)
    )

    /// How close the pinch point must be to an object's centre, across the table and in height, for closing
    /// the jaws to take hold of it. In the simulator the window is a few millimetres either way.
    var graspTolerance = SIMD2<Float>(0.006, 0.008)

    /// Where the jaws pinch, robot base frame.
    func toolPoint(reported arm: SIMD3<Float>) -> SIMD3<Float> { arm + toolOffset }
    /// A world-frame position in the robot base frame.
    func inBase(world: SIMD3<Float>) -> SIMD3<Float> { world - baseInWorld }
}

/// Where the thing to reach is, as the operator sees it, so the task does not have to be done by eye alone.
struct Guidance: Equatable {
    enum Target: Equatable { case cube, goal, done }

    var target: Target
    /// Metres right, forward and up from where the jaws pinch to the target. Zero means: close the gripper.
    var offset: SIMD3<Float>
    /// Where things are, in metres as the operator sees them: x right, y forward, z up. For the map.
    /// `arm` is where the jaws pinch, not the point the server reports.
    var arm = SIMD3<Float>.zero
    var cube = SIMD3<Float>.zero
    var goal = SIMD3<Float>.zero
    /// The arm stopped following in the direction it is being asked to go: it is at the edge of its range.
    var atEdge = false
    /// The jaws are around the cube: closing them now takes hold of it.
    var readyToGrasp = false

    /// How close, flat on the table, the gripper must be to the cube to count as holding it once closed.
    static let holdingRadius: Float = 0.03
    /// Half-size of the goal area on the table, as the server judges success.
    static let goalHalfExtent: Float = 0.025

    /// Positions as the server reports them, metres: the arm in the robot base frame, cube and goal in the world.
    static func make(
        arm reported: SIMD3<Float>, cube worldCube: SIMD3<Float>, goal worldGoal: SIMD3<Float>,
        gripper: GripperState?, profile: RobotProfile = .so101Simulator
    ) -> Guidance {
        let arm = profile.toolPoint(reported: reported)
        let cube = profile.inBase(world: worldCube), goal = profile.inBase(world: worldGoal)
        let cubeToGoal = goal - cube
        let places = (operatorOffset(arm), operatorOffset(cube), operatorOffset(goal))
        if abs(cubeToGoal.x) <= goalHalfExtent, abs(cubeToGoal.y) <= goalHalfExtent {
            return Guidance(target: .done, offset: .zero, arm: places.0, cube: places.1, goal: places.2)
        }
        let flat = SIMD2(cube.x - arm.x, cube.y - arm.y)
        let holding = gripper == .closed && simd_length(flat) <= holdingRadius
        // Carrying: steer the cube, which moves with the gripper, to the goal. Otherwise steer the gripper to the cube.
        let base = holding ? cubeToGoal : cube - arm
        let ready = !holding && gripper != .closed
            && simd_length(flat) <= profile.graspTolerance.x && abs(cube.z - arm.z) <= profile.graspTolerance.y
        return Guidance(
            target: holding ? .goal : .cube, offset: operatorOffset(base),
            arm: places.0, cube: places.1, goal: places.2, readyToGrasp: ready
        )
    }

    /// Robot base to operator directions. The server maps right → −X, forward → −Y, up → +Z.
    static func operatorOffset(_ base: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(-base.x, -base.y, base.z)
    }
}

/// Where to draw the gripper, the cube and the goal on a square top-down map, and on the height bar beside it.
/// Up on the map is forward for the operator, right is right. The map zooms to keep all three in view.
struct MiniMapLayout: Equatable {
    /// Edge of the cube and of the goal area, metres.
    static let cubeSize: Float = 0.025
    static let goalSize: Float = 0.05
    /// The map never shows less than this across, so small moves do not look huge.
    static let minimumSpan: Float = 0.14
    /// Room kept around the outermost thing.
    static let margin: Float = 0.03
    /// Height the bar covers above the cube's resting height.
    static let barHeight: Float = 0.14

    let centre: SIMD2<Float>
    let span: Float
    let floor: Float
    let arm: SIMD3<Float>
    let cube: SIMD3<Float>
    let goal: SIMD3<Float>

    init(_ guidance: Guidance) {
        arm = guidance.arm
        goal = guidance.goal
        // A held cube travels with the gripper; the server's last word on it is from before the hold.
        cube = guidance.target == .goal ? SIMD3(guidance.arm.x, guidance.arm.y, guidance.cube.z) : guidance.cube
        let xs = [arm.x, cube.x, goal.x], ys = [arm.y, cube.y, goal.y]
        centre = SIMD2((xs.min()! + xs.max()!) / 2, (ys.min()! + ys.max()!) / 2)
        span = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!, Self.minimumSpan - 2 * Self.margin) + 2 * Self.margin
        floor = min(guidance.cube.z, guidance.goal.z) - Self.cubeSize / 2
    }

    /// Position on a map `side` points square, origin top-left.
    func point(_ place: SIMD3<Float>, side: Float) -> SIMD2<Float> {
        SIMD2(
            (place.x - centre.x) / span * side + side / 2,
            // Forward is up, and screen y grows downward.
            side / 2 - (place.y - centre.y) / span * side
        )
    }

    func length(_ meters: Float, side: Float) -> Float { meters / span * side }

    /// Distance down from the top of a bar `height` points tall; clamped so a marker never leaves the bar.
    func barOffset(_ z: Float, height: Float) -> Float {
        let share = min(max((z - floor) / Self.barHeight, 0), 1)
        return height * (1 - share)
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
