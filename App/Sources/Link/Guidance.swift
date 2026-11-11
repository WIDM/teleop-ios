import simd
import TeleopCore

/// What the app has to know about one robot setup to put the arm and the things around it in one picture.
/// The server's state does not carry these, so each setup the app drives needs a profile.
struct RobotProfile: Equatable {
    var name: String
    /// From the point the server reports for the arm (the gripper link origin) to where the jaws pinch,
    /// in the robot base frame, metres. Holds while the wrist joints stay put, as in translation mode.
    /// This is the grasp point with the jaws turned sideways, measured on the S4 simulator on 2026-11-11:
    /// the reported point sat at the cube's centre plus (−0.007, +0.036, +0.088) m. The front-to-back grasp it
    /// replaces lifted the cube 1 time in 16.
    var toolOffset: SIMD3<Float>
    /// Where the robot base sits in the world frame, metres. The server reports the arm in the base frame
    /// and objects in the world frame; this brings objects into the base frame.
    var baseInWorld: SIMD3<Float>

    /// The SO-101 in the S4 pick-and-place simulator. The base height is ROBOT_BASE_POS_W in the simulator's source.
    static let so101Simulator = RobotProfile(
        name: "SO-101 (S4 simulator)",
        toolOffset: SIMD3(0.007, -0.036, -0.088),
        baseInWorld: SIMD3(0, 0, 0.05)
    )

    /// How close the pinch point must be to an object's centre, across the table and in height, for closing
    /// the jaws to take hold of it. In the simulator the window is a few millimetres either way.
    var graspTolerance = SIMD2<Float>(0.006, 0.008)
    /// Size across of the task object and of the goal area on the table, metres, for drawing them true to size.
    /// The goal is the box the server judges success in.
    var targetSize: Float = 0.025
    var goalSize: Float = 0.05
    /// A measured jaw angle at or above this while opening is fully open. The joint's limit is 100 degrees.
    var gripperOpenDeg = 97.0
    /// At or below this while closing, with no contact, the jaws closed on nothing. An empty close settled at
    /// 0.4 degrees on the S4 simulator (recording s15); this is that plus 2, until the device check sets it.
    var gripperEmptyDeg = 2.0
    /// The scene's start pose already has the jaws side by side, which is the grasp `toolOffset` was measured
    /// for. True for the development simulator since 2026-11-11 (its start wrist roll is 90 degrees). The server
    /// as published starts them front to back, and there the operator has to turn them first: two full presses.
    var jawsStartSideways = true
    /// The box the server keeps the pinch point inside, robot base frame, metres. The simulator clamps the point it
    /// reports to 8 cm either way of where that point is after a reset (`WORKSPACE_RADIUS_M` around
    /// `initial_ee_pos_b`); this is that box moved by `toolOffset`, so it holds while the wrist keeps its start pose.
    var workspaceMin = SIMD3<Float>(-0.052383, -0.257418, -0.008015)
    var workspaceMax = SIMD3<Float>(0.107617, -0.097418, 0.151985)
    /// Height of the table surface in the robot base frame, metres (`TABLE_TOP_Z_M` minus the base height).
    var tableHeight: Float = 0.04
    /// Server wrist roll = `rollSign` × the phone's turn, and server wrist flex = `tiltSign` × its tilt. +1 until the
    /// live mapping check (C-I5) measures them.
    var rollSign = 1.0
    var tiltSign = 1.0
    /// Closing the jaws again after they met something loosens the grip, because a close starts from the measured
    /// angle; so a second close is refused until they have opened. True for this simulator. A robot that must squeeze
    /// harder to hold would set it false.
    var recloseLoosensGrip = true

    var gripperLimits: GripperLimits { GripperLimits(openDeg: gripperOpenDeg, emptyDeg: gripperEmptyDeg) }

    /// The input rules' thresholds with this robot's wrist signs.
    var inputConstants: InputConstants {
        var constants = InputConstants.appendixA
        constants.rollSign = rollSign
        constants.tiltSign = tiltSign
        return constants
    }

    /// Where the jaws pinch, robot base frame.
    func toolPoint(reported arm: SIMD3<Float>) -> SIMD3<Float> { arm + toolOffset }
    /// A world-frame position in the robot base frame.
    func inBase(world: SIMD3<Float>) -> SIMD3<Float> { world - baseInWorld }
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
