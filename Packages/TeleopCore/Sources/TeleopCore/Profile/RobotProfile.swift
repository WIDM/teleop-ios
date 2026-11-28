/// What the app has to know about one robot setup to put the arm and the things around it in one picture.
/// The server's state does not carry these, so each setup the app drives needs a profile.
public struct RobotProfile: Equatable, Sendable {
    /// A name for people, such as in a log. Code never decides anything by it.
    public var name: String
    /// From the point the server reports for the arm (the gripper link origin) to where the jaws pinch, in the robot
    /// base frame, metres. Holds while the wrist joints stay as they were where it was measured. A file's
    /// `scene.tool_offset.offset_m`; docs/PROFILE.md tells how each robot's was measured.
    public var toolOffset: SIMD3<Float>
    /// Where `toolOffset` was measured: the reported point (the object's resting centre minus `toolOffset`), robot base
    /// frame, metres, and the wrist flex and roll there, degrees. There the estimate is exact.
    public var offsetMeasuredAt: SIMD3<Float>
    public var offsetMeasuredFlexDeg: Double
    public var offsetMeasuredRollDeg: Double
    /// How far the estimate may be off away from where `toolOffset` was measured.
    public var estimateBound: EstimateBound
    /// How the operator's view, the robot base, the link and the world relate: which base axis is forward, left and
    /// up, how the link's offsets are signed against the base's, and where the base sits in the world frame and how
    /// it is turned there. The server reports the arm in the base frame and objects in the world frame; the frames
    /// bring objects into the base frame.
    public var frames: Frames
    /// How close the pinch point must be to an object's centre, across the table and in height, metres, for closing
    /// the jaws to take hold of it.
    public var graspTolerance: SIMD2<Float>
    /// Size across of the task object and of the goal area on the table, metres, for drawing them true to size.
    /// The goal is the box the server judges success in.
    public var targetSize: Float
    public var goalSize: Float
    /// What the jaw readings mean: their unit, the readings the opening share is drawn between, the readings that
    /// count, and the two thresholds "fully open" and "closed on nothing".
    public var gripper: GripperProfile
    /// The box the server keeps the pinch point inside, robot base frame, metres. It holds while the wrist keeps its
    /// start pose; with a reported tool point the guide moves it by the measured offset instead
    /// (`ArmReading.boxShift`).
    public var workspaceMin: SIMD3<Float>
    public var workspaceMax: SIMD3<Float>
    /// Height of the table surface over the robot base origin, metres, along up (`frames.height(of:)`): the base's
    /// own z when z is up, the other way round when it points down.
    public var tableHeight: Float
    /// The wrist: the windows and per-hold limits, the signs of the phone's turn and tilt and of the wrist buttons,
    /// the buttons' rates and the lead bound.
    public var wrist: WristProfile
    /// How fast the buttons move the arm and how far a command may run ahead of it.
    public var motion: MotionProfile
    /// What the app plans around in the server: its stop distance, resync times and the point that holds an object.
    public var server: ServerProfile
    /// True when closing the jaws again after they met something would loosen the grip (a close starts from the
    /// measured angle), so a second close is refused until they have opened. False for a robot that must squeeze
    /// harder to hold.
    public var recloseLoosensGrip: Bool
    /// True when this robot's gripper-link box has been checked against the server's workspace, so "Blocked." may be
    /// told by the direction asked.
    public var usesDirectionalBlockedFeedback: Bool
    /// Which hands-free aids this robot allows, with their numbers. A robot allows lock exactly when `assist.lock` is
    /// set, and cannot allow it without saying how long a follow nobody holds may run. `.none` allows none of them and
    /// needs no code path of its own.
    public var assist: AssistProfile
    /// A window for the guide's "On target" and its cue (across, height; metres), no narrower than `graspTolerance`,
    /// used when the guide's aids ask for it. Nil: the grasp tolerance. `graspTolerance` keeps its other jobs (the
    /// level word, the approximate threshold, parity with the server model).
    public var onTargetWindow: SIMD2<Float>?

    public init(
        name: String,
        toolOffset: SIMD3<Float>,
        offsetMeasuredAt: SIMD3<Float>,
        offsetMeasuredFlexDeg: Double,
        offsetMeasuredRollDeg: Double,
        estimateBound: EstimateBound,
        frames: Frames,
        graspTolerance: SIMD2<Float>,
        targetSize: Float,
        goalSize: Float,
        gripper: GripperProfile,
        workspaceMin: SIMD3<Float>,
        workspaceMax: SIMD3<Float>,
        tableHeight: Float,
        wrist: WristProfile,
        motion: MotionProfile,
        server: ServerProfile,
        recloseLoosensGrip: Bool,
        usesDirectionalBlockedFeedback: Bool,
        assist: AssistProfile,
        onTargetWindow: SIMD2<Float>?
    ) {
        self.name = name
        self.toolOffset = toolOffset
        self.offsetMeasuredAt = offsetMeasuredAt
        self.offsetMeasuredFlexDeg = offsetMeasuredFlexDeg
        self.offsetMeasuredRollDeg = offsetMeasuredRollDeg
        self.estimateBound = estimateBound
        self.frames = frames
        self.graspTolerance = graspTolerance
        self.targetSize = targetSize
        self.goalSize = goalSize
        self.gripper = gripper
        self.workspaceMin = workspaceMin
        self.workspaceMax = workspaceMax
        self.tableHeight = tableHeight
        self.wrist = wrist
        self.motion = motion
        self.server = server
        self.recloseLoosensGrip = recloseLoosensGrip
        self.usesDirectionalBlockedFeedback = usesDirectionalBlockedFeedback
        self.assist = assist
        self.onTargetWindow = onTargetWindow
    }

    public var gripperWorkspace: (low: SIMD3<Double>, high: SIMD3<Double>) {
        (SIMD3<Double>(workspaceMin - toolOffset), SIMD3<Double>(workspaceMax - toolOffset))
    }

    public var gripperLimits: GripperLimits { gripper.limits }

    /// Server wrist roll = `rollSign` × the phone's turn, and server wrist flex = `tiltSign` × its tilt; 1 or -1.
    public var rollSign: Double {
        get { wrist.rollSign }
        set { wrist.rollSign = newValue }
    }
    public var tiltSign: Double {
        get { wrist.tiltSign }
        set { wrist.tiltSign = newValue }
    }

    /// The input rules' thresholds: the wrist's from this robot's profile, the touch and key ones as the app has them.
    public var inputConstants: InputConstants { InputConstants(wrist: wrist) }

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

    /// The estimate may be off by more than half the grasp tolerance across: the guide draws it approximate. The bound
    /// overestimates by centimetres, so it decides only this and never sizes anything.
    public func estimateIsApproximate(gripper: SIMD3<Float>, flexDeg: Double?, rollDeg: Double?) -> Bool {
        guard let error = estimateError(gripper: gripper, flexDeg: flexDeg, rollDeg: rollDeg) else { return true }
        return error > graspTolerance.x / 2
    }

    /// Where the robot base sits in the world frame, metres: the shift of `frames`.
    public var baseInWorld: SIMD3<Float> {
        get { SIMD3<Float>(frames.baseInWorld) }
        set { frames.baseInWorld = SIMD3<Double>(newValue) }
    }

    /// The work box's floor, along up, lies below the table: the table stops the arm before it reaches the box's bottom
    /// face.
    public var workspaceFloorIsBelowTable: Bool {
        let floor = min(
            frames.height(of: SIMD3<Double>(workspaceMin)), frames.height(of: SIMD3<Double>(workspaceMax)))
        return floor < Double(tableHeight)
    }

    /// A world-frame position in the robot base frame.
    public func inBase(world: SIMD3<Float>) -> SIMD3<Float> { frames.base(fromWorld: world) }
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
