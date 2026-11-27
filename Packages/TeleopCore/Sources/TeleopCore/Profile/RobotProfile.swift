/// What the app has to know about one robot setup to put the arm and the things around it in one picture.
/// The server's state does not carry these, so each setup the app drives needs a profile.
public struct RobotProfile: Equatable, Sendable {
    public var name: String
    /// From the point the server reports for the arm (the gripper link origin) to where the jaws pinch,
    /// in the robot base frame, metres. Holds while the wrist joints stay put, as in translation mode.
    /// This is the grasp point with the jaws turned sideways, measured on the S4 simulator on 2026-11-11:
    /// the reported point sat at the cube's centre plus (−0.007, +0.036, +0.088) m. The front-to-back grasp it
    /// replaces lifted the cube 1 time in 16. The scene starts with the jaws sideways (a start wrist roll of
    /// 90 degrees), so the point holds from the start pose; a scene that starts them front to back needs another.
    public var toolOffset: SIMD3<Float>
    /// Where `toolOffset` was measured: the reported point (the cube's resting centre minus `toolOffset`), robot base
    /// frame, metres, and the measured wrist flex and roll, degrees. There the estimate is exact.
    public var offsetMeasuredAt: SIMD3<Float>
    public var offsetMeasuredFlexDeg: Double
    public var offsetMeasuredRollDeg: Double
    /// How far the estimate may be off elsewhere. Computed from the SO-101's description and the server's solver:
    /// fitted never to underestimate within 6 cm across and 5 cm above the measured place, tested with tilt and turn up
    /// to 30 degrees. +y is toward the base. Below the measured height, where the fit has no places, the rate for up
    /// is used; outside the fitted region the bound is already over 10 mm.
    public var estimateBound: EstimateBound
    /// Where the robot base sits in the world frame, metres. The server reports the arm in the base frame
    /// and objects in the world frame; this brings objects into the base frame.
    public var baseInWorld: SIMD3<Float>
    /// How close the pinch point must be to an object's centre, across the table and in height, for closing
    /// the jaws to take hold of it. In the simulator the window is a few millimetres either way.
    public var graspTolerance: SIMD2<Float>
    /// Size across of the task object and of the goal area on the table, metres, for drawing them true to size.
    /// The goal is the box the server judges success in.
    public var targetSize: Float
    public var goalSize: Float
    /// A measured jaw angle at or above this while opening is fully open. The joint's limit is 100 degrees.
    public var gripperOpenDeg: Double
    /// At or below this when a close has ended with no contact, the jaws closed on nothing. An empty close settled at
    /// 0.4 degrees on the S4 simulator (recording s15); this is that plus 2, until the device check sets it.
    public var gripperEmptyDeg: Double
    /// The box the server keeps the pinch point inside, robot base frame, metres. The simulator clamps the point it
    /// reports to 8 cm either way of where that point is after a reset (`WORKSPACE_RADIUS_M` around
    /// `initial_ee_pos_b`); this is that box moved by `toolOffset`, so it holds while the wrist keeps its start pose.
    /// With a reported tool point the guide moves it by the measured offset instead (`ArmReading.boxShift`).
    public var workspaceMin: SIMD3<Float>
    public var workspaceMax: SIMD3<Float>
    /// Height of the table surface in the robot base frame, metres (`TABLE_TOP_Z_M` minus the base height).
    public var tableHeight: Float
    /// Server wrist roll = `rollSign` × the phone's turn, and server wrist flex = `tiltSign` × its tilt. +1 until the
    /// live mapping check (C-I5) measures them.
    public var rollSign: Double
    public var tiltSign: Double
    /// Closing the jaws again after they met something loosens the grip, because a close starts from the measured
    /// angle; so a second close is refused until they have opened. True for this simulator. A robot that must squeeze
    /// harder to hold would set it false.
    public var recloseLoosensGrip: Bool
    /// This profile's gripper-link box has been checked against the workspace in the server recording.
    public var usesDirectionalBlockedFeedback: Bool
    /// Which hands-free aids this robot allows, with their numbers. A robot allows lock exactly when `assist.lock` is
    /// set, and cannot allow it without saying how long a follow nobody holds may run. `.none` allows none of them and
    /// needs no code path of its own.
    public var assist: AssistProfile
    /// A wider window for the guide's "On target" and its cue (across, height; metres), used when the guide's aids ask
    /// for it. Nil: the grasp tolerance. `graspTolerance` keeps its other jobs (the level word, the approximate
    /// threshold, parity with the server model).
    public var onTargetWindow: SIMD2<Float>?

    public init(
        name: String,
        toolOffset: SIMD3<Float>,
        offsetMeasuredAt: SIMD3<Float> = SIMD3<Float>(-0.002, -0.164, 0.1405),
        offsetMeasuredFlexDeg: Double = 40.24,
        offsetMeasuredRollDeg: Double = 90.0,
        estimateBound: EstimateBound = EstimateBound(
            xMmPerCm: 2.56, plusYMmPerCm: 11.12, minusYMmPerCm: 1.80, zMmPerCm: 8.43, flexMmPerDeg: 1.65,
            rollMmPerDeg: 0.23
        ),
        baseInWorld: SIMD3<Float>,
        graspTolerance: SIMD2<Float> = SIMD2<Float>(0.006, 0.008),
        targetSize: Float = 0.025,
        goalSize: Float = 0.05,
        gripperOpenDeg: Double = 97.0,
        gripperEmptyDeg: Double = 2.0,
        workspaceMin: SIMD3<Float> = SIMD3<Float>(-0.052383, -0.257418, -0.008015),
        workspaceMax: SIMD3<Float> = SIMD3<Float>(0.107617, -0.097418, 0.151985),
        tableHeight: Float = 0.04,
        rollSign: Double = 1.0,
        tiltSign: Double = 1.0,
        recloseLoosensGrip: Bool = true,
        usesDirectionalBlockedFeedback: Bool = false,
        assist: AssistProfile = .none,
        onTargetWindow: SIMD2<Float>? = nil
    ) {
        self.name = name
        self.toolOffset = toolOffset
        self.offsetMeasuredAt = offsetMeasuredAt
        self.offsetMeasuredFlexDeg = offsetMeasuredFlexDeg
        self.offsetMeasuredRollDeg = offsetMeasuredRollDeg
        self.estimateBound = estimateBound
        self.baseInWorld = baseInWorld
        self.graspTolerance = graspTolerance
        self.targetSize = targetSize
        self.goalSize = goalSize
        self.gripperOpenDeg = gripperOpenDeg
        self.gripperEmptyDeg = gripperEmptyDeg
        self.workspaceMin = workspaceMin
        self.workspaceMax = workspaceMax
        self.tableHeight = tableHeight
        self.rollSign = rollSign
        self.tiltSign = tiltSign
        self.recloseLoosensGrip = recloseLoosensGrip
        self.usesDirectionalBlockedFeedback = usesDirectionalBlockedFeedback
        self.assist = assist
        self.onTargetWindow = onTargetWindow
    }

    public var gripperWorkspace: (low: SIMD3<Double>, high: SIMD3<Double>) {
        (SIMD3<Double>(workspaceMin - toolOffset), SIMD3<Double>(workspaceMax - toolOffset))
    }

    public var gripperLimits: GripperLimits { GripperLimits(openDeg: gripperOpenDeg, emptyDeg: gripperEmptyDeg) }

    /// The input rules' thresholds with this robot's wrist signs.
    public var inputConstants: InputConstants {
        var constants = InputConstants.appendixA
        constants.rollSign = rollSign
        constants.tiltSign = tiltSign
        return constants
    }

    /// How far the estimated pinch point may be from the true one, metres, by `estimateBound`, with the gripper point
    /// and wrist angles of one reading. Nil without both wrist angles: a tilt alone moves the true point centimetres.
    public func estimateError(gripper: SIMD3<Float>, flexDeg: Double?, rollDeg: Double?) -> Float? {
        guard let flexDeg, let rollDeg else { return nil }
        let moved = (gripper - offsetMeasuredAt) * 100
        let b = estimateBound
        let millimetres =
            b.xMmPerCm * abs(moved.x) + b.plusYMmPerCm * max(moved.y, 0) + b.minusYMmPerCm * max(-moved.y, 0)
            + b.zMmPerCm * abs(moved.z) + b.flexMmPerDeg * Float(abs(flexDeg - offsetMeasuredFlexDeg))
            + b.rollMmPerDeg * Float(abs(rollDeg - offsetMeasuredRollDeg))
        return millimetres / 1000
    }

    /// The estimate may be off by more than half the grasp tolerance across: the guide draws it approximate. Half,
    /// because a lift needed the jaws within about 1 cm in the hand sessions and the tolerance is 6 mm. The bound
    /// overestimates by centimetres, so it decides only this and never sizes anything.
    public func estimateIsApproximate(gripper: SIMD3<Float>, flexDeg: Double?, rollDeg: Double?) -> Bool {
        guard let error = estimateError(gripper: gripper, flexDeg: flexDeg, rollDeg: rollDeg) else { return true }
        return error > graspTolerance.x / 2
    }

    /// A world-frame position in the robot base frame.
    public func inBase(world: SIMD3<Float>) -> SIMD3<Float> { world - baseInWorld }
}

/// A bound on how far an estimated pinch point is from the true one, in millimetres: so many per centimetre the
/// reported gripper point has moved from where the offset was measured, along each axis of the robot base frame (x and
/// z either way, +y and −y apart), plus so many per degree the wrist's flex and roll are from their measured values.
public struct EstimateBound: Equatable, Sendable {
    public var xMmPerCm: Float
    public var plusYMmPerCm: Float
    public var minusYMmPerCm: Float
    public var zMmPerCm: Float
    public var flexMmPerDeg: Float
    public var rollMmPerDeg: Float

    public init(
        xMmPerCm: Float, plusYMmPerCm: Float, minusYMmPerCm: Float, zMmPerCm: Float, flexMmPerDeg: Float,
        rollMmPerDeg: Float
    ) {
        self.xMmPerCm = xMmPerCm
        self.plusYMmPerCm = plusYMmPerCm
        self.minusYMmPerCm = minusYMmPerCm
        self.zMmPerCm = zMmPerCm
        self.flexMmPerDeg = flexMmPerDeg
        self.rollMmPerDeg = rollMmPerDeg
    }
}
