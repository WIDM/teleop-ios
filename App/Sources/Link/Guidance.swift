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
    /// replaces lifted the cube 1 time in 16. The scene starts with the jaws sideways (a start wrist roll of
    /// 90 degrees), so the point holds from the start pose; a scene that starts them front to back needs another.
    var toolOffset: SIMD3<Float>
    /// Where `toolOffset` was measured: the reported point (the cube's resting centre minus `toolOffset`), robot base
    /// frame, metres, and the measured wrist flex and roll, degrees. There the estimate is exact.
    var offsetMeasuredAt = SIMD3<Float>(-0.002, -0.164, 0.1405)
    var offsetMeasuredFlexDeg = 40.24
    var offsetMeasuredRollDeg = 90.0
    /// How far the estimate may be off elsewhere. Computed from the SO-101's description and the server's solver:
    /// fitted never to underestimate within 6 cm across and 5 cm above the measured place, tested with tilt and turn up
    /// to 30 degrees. +y is toward the base. Below the measured height, where the fit has no places, the rate for up
    /// is used; outside the fitted region the bound is already over 10 mm.
    var estimateBound = EstimateBound(
        xMmPerCm: 2.56, plusYMmPerCm: 11.12, minusYMmPerCm: 1.80, zMmPerCm: 8.43, flexMmPerDeg: 1.65, rollMmPerDeg: 0.23
    )
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
    /// The box the server keeps the pinch point inside, robot base frame, metres. The simulator clamps the point it
    /// reports to 8 cm either way of where that point is after a reset (`WORKSPACE_RADIUS_M` around
    /// `initial_ee_pos_b`); this is that box moved by `toolOffset`, so it holds while the wrist keeps its start pose.
    /// With a reported tool point the guide moves it by the measured offset instead (`ArmReading.boxShift`).
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

    /// How far the estimated pinch point may be from the true one, metres, by `estimateBound`, with the gripper point
    /// and wrist angles of one reading. Nil without both wrist angles: a tilt alone moves the true point centimetres.
    func estimateError(gripper: SIMD3<Float>, flexDeg: Double?, rollDeg: Double?) -> Float? {
        guard let flexDeg, let rollDeg else { return nil }
        let moved = (gripper - offsetMeasuredAt) * 100
        let b = estimateBound
        let millimetres =
            b.xMmPerCm * abs(moved.x) + b.plusYMmPerCm * max(moved.y, 0) + b.minusYMmPerCm * max(-moved.y, 0)
            + b.zMmPerCm * abs(moved.z) + b.flexMmPerDeg * Float(abs(flexDeg - offsetMeasuredFlexDeg))
            + b.rollMmPerDeg * Float(abs(rollDeg - offsetMeasuredRollDeg))
        return millimetres / 1000
    }

    /// The estimate may be off by more than half the on-target window across: the guide draws it approximate. Half,
    /// because a lift needed the jaws within about 1 cm in the hand sessions and the window is 6 mm. The bound
    /// overestimates by centimetres, so it decides only this and never sizes anything.
    func estimateIsApproximate(gripper: SIMD3<Float>, flexDeg: Double?, rollDeg: Double?) -> Bool {
        guard let error = estimateError(gripper: gripper, flexDeg: flexDeg, rollDeg: rollDeg) else { return true }
        return error > graspTolerance.x / 2
    }

    /// A world-frame position in the robot base frame.
    func inBase(world: SIMD3<Float>) -> SIMD3<Float> { world - baseInWorld }
}

/// A bound on how far an estimated pinch point is from the true one, in millimetres: so many per centimetre the
/// reported gripper point has moved from where the offset was measured, along each axis of the robot base frame (x and
/// z either way, +y and −y apart), plus so many per degree the wrist's flex and roll are from their measured values.
struct EstimateBound: Equatable {
    var xMmPerCm: Float
    var plusYMmPerCm: Float
    var minusYMmPerCm: Float
    var zMmPerCm: Float
    var flexMmPerDeg: Float
    var rollMmPerDeg: Float
}

/// Where the pinch point of one reading came from.
enum PinchSource: Equatable, Sendable {
    /// The server reported it (`tool_pos`). Never approximate.
    case reported
    /// The reported gripper point plus the profile's `toolOffset`. `approximate`: it may be off by more than half the
    /// on-target window, so the guide draws it hollow, says so, and never says "On target".
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
