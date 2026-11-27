import Foundation

/// Every robot, task and protocol number the server model uses, in one place.
///
/// Unless a line says otherwise, a value is the S4 simulator server's own constant (2026-11-11) or a value measured
/// from recordings of it. The model behaves as the app expects a server to: `state` carries the recorder, the
/// measured wrist and jaw angles and, unless `reportsToolPoint` is off, the tool point; a take starts with a held
/// command, and a held control keeps the targets it was given when it starts, ends or is ended by the watchdog.
/// Lengths are metres, angles degrees, positions in the robot base frame unless the name ends in `World`.
public struct ServerModelConfig: Equatable, Sendable {
    // MARK: Pace

    /// Physics steps per wall-clock second. The real loop managed 14 to 19 with no cameras and 8 to 9 with
    /// cameras (measured 2026-11-04 to 11-11); 17 matches the recordings. The socket host runs faster.
    public var stepsPerSecond: Double = 17
    /// Simulated seconds per physics step. Every speed below is per simulated second.
    public var simStep: Double = 1.0 / 60
    /// A scene reset: 30 steps for the robot to settle, then 15 for the cube.
    public var resetSteps = 45

    // MARK: Protocol (wall clock)

    /// A held control ends this long after its last update or keepalive.
    public var holdWatchdog: Double = 0.75
    /// `state` goes out after this much silence from a client, and again every time it passes.
    public var stateInterval: Double = 0.2
    /// A one-shot command (`move_delta`, `joint_delta`, `gripper`, `reset_scene`) must be taken this soon.
    public var commandDeadline: Double = 45
    /// Identifies the server run in `welcome`; the real one is a fresh UUID per launch.
    public var session = "00000000-0000-4000-8000-000000000000"
    /// `ts` of the first instant, in milliseconds. Every message carries `ts` = this + the model's time.
    public var clockOriginMs = 0
    /// The simulation loop counts as stalled once its last pass is this old while the server is ready. A pass takes
    /// about 17 ms; a rendered one well under 0.1 s.
    public var loopStallSeconds: Double = 1.0
    /// `state` carries `sim_stalled` and `loop_age_ms`, as a server with the loop heartbeat does. Off by default: the
    /// recordings the model is checked against come from a server without them.
    public var reportsLoopHealth = false

    // MARK: Scene

    /// The robot base in the world frame. The server reports the arm in the base frame and objects in the world frame.
    public var baseInWorld = SIMD3<Double>(0, 0, 0.05)
    /// Which way each axis of the base points in the world, each a unit vector along a world axis (a quarter turn).
    /// World z is up: the table, the floor and a falling cube are rules of the world, so "up" in the base frame is
    /// whichever base axis lies along world z, and a base whose z points down has the table along its own z the
    /// other way round.
    public var baseXInWorld = SIMD3<Double>(1, 0, 0)
    public var baseYInWorld = SIMD3<Double>(0, 1, 0)
    public var baseZInWorld = SIMD3<Double>(0, 0, 1)
    /// The server moves the base by a translation hold's offset with each axis signed like this, the phone's frame
    /// against the base's (mapping `phone_axes_20261025_v1`: x, y, minus z).
    public var linkSigns = SIMD3<Double>(1, 1, -1)
    /// The point the server reports for the arm (the gripper link origin) after a reset, as measured.
    public var armStart = SIMD3<Double>(0.020617, -0.141418, 0.159985)
    /// The workspace is a box this far either way of `armStart` on every axis.
    public var workspaceHalfSize = 0.08
    /// The cube's centre after a reset, resting on the table, as measured.
    public var cubeStartWorld = SIMD3<Double>(0.005, -0.2, 0.1025)
    public var cubeSize = 0.025
    public var goalWorld = SIMD3<Double>(0.075, -0.2, 0.1035)
    public var goalHalfExtents = SIMD3<Double>(0.025, 0.025, 0.020)
    public var tableTopWorld = 0.09
    /// The table's extent across, world frame. A cube let go outside it falls to the floor.
    public var tableMinWorld = SIMD2<Double>(-0.115, -0.34)
    public var tableMaxWorld = SIMD2<Double>(0.185, -0.04)
    /// A cube whose centre drops below this, with no command running, resets the scene.
    public var fallenCubeHeightWorld = 0.03

    // MARK: Robot

    /// From the reported point to where the jaws pinch, base frame (the app's SO-101 profile file).
    public var toolOffset = SIMD3<Double>(0.007, -0.036, -0.088)
    /// Model choice: nil keeps the pinch point at the reported point plus `toolOffset` wherever the arm is, as the
    /// app's profile assumes. Set, the pinch point turns with the arm's posture as the gripper does on the simulator
    /// (`ToolTurn`), and `toolOffset` is not used: the tool point in `state`, the grasp and where the jaw tips stop on
    /// the table all follow the turning point. It is written for a base whose z is up (the pan axis, the tilt and the
    /// drop below the reported point are all along z), so a model whose base is turned cannot carry one.
    public var toolTurn: ToolTurn?
    /// `state` carries `tool_pos`, the pinch point, wherever it carries `ee_pos`. False leaves it out, as from a server
    /// that reports no tool point. The model starts from this and can be told to stop during a run
    /// (`ServerModel.reportsToolPoint`).
    public var reportsToolPoint = true
    /// How close the pinch point must be to the cube's centre, across the table and in height, for closing
    /// the jaws to take hold of it (the app's `RobotProfile.graspTolerance`).
    public var graspToleranceAcross = 0.006
    public var graspToleranceHeight = 0.008
    /// The wrist and jaws after a reset, as measured. Roll 90 is jaws side by side, the grasp the tool offset is for;
    /// a scene that starts at roll 0 has them front to back.
    public var wristFlexStart = 40.24
    public var wristRollStart = 90.0
    public var jawStart = 0.0
    /// Wrist roll with the jaws side by side.
    public var sidewaysRoll = 90.0
    /// Model choice: the grasp works with the wrist roll within this of `sidewaysRoll`. Front to back, the real
    /// grasp lifted the cube 1 time in 16, so the model does not grasp at all.
    public var sidewaysRollTolerance = 15.0
    /// Model choice: the tool offset holds only near the start pitch; a few degrees move the real jaw tips
    /// further than the grasp tolerance, so the model grasps only within this of `wristFlexStart`.
    public var graspFlexTolerance = 3.0
    /// Jaw angle at which closing jaws meet the cube. The median of the real server's contact stops on 2026-11-11 (8).
    public var jawAngleOnCube = 8.0
    /// Model choice: the jaw tips reach this far below the pinch point. They stop on the table there.
    public var jawReachBelowPinch = 0.005

    /// Soft joint limits, as the server logs them.
    public var wristFlexLimits = -95.0...95.0
    public var wristRollLimits = -160.0...160.0
    public var jawLimits = -10.0...100.0
    public var armJointLimits: [String: ClosedRange<Double>] = [
        "shoulder_pan": -110...110, "shoulder_lift": -100...100, "elbow_flex": -100...90,
    ]
    public var armJointStart: [String: Double] = ["shoulder_pan": 0, "shoulder_lift": -60, "elbow_flex": 70]

    // MARK: Motion (per simulated second unless named per step)

    /// How far the reported point can follow its commanded point in one step. The server limits each joint's
    /// change per step (0.025 rad in pose holds, 0.01 rad in jogs and moves); the fastest real holds moved
    /// the point 2.5 and 1.1 mm per step (hold diagnostics, 2026-11-11).
    public var armStepInPose = 0.0025
    public var armStepInJog = 0.0011
    /// A pose hold's commanded point moves toward the phone's target at this speed, slower while carrying.
    public var poseSpeed = 0.40
    public var poseCarrySpeed = 0.12
    /// A pose hold's `gripper_delta` beyond this either way relabels the gripper "open" or "close".
    public var poseGripperLabelThreshold = 0.02
    /// `gripper_delta` in a pose hold moves the jaw target by this many degrees per unit, at these rates.
    public var poseJawRange = 110.0
    public var poseJawOpenRate = 90.0
    public var poseJawCloseRate = 30.0
    public var jogSpeed: [String: Double] = ["fine": 0.090, "coarse": 0.180]
    public var jogCarrySpeed: [String: Double] = ["fine": 0.030, "coarse": 0.060]
    public var jointJogRate: [String: Double] = ["fine": 45, "coarse": 90]
    public var jointJogCarryRate: [String: Double] = ["fine": 15, "coarse": 30]
    public var gripperJogOpenRate: [String: Double] = ["fine": 90, "coarse": 180]
    public var gripperJogCloseRate: [String: Double] = ["fine": 30, "coarse": 60]
    /// The wrist target moves at most this much per step in orient and pose-wrist holds (0.01 rad).
    public var wristStepPerStep = 0.01 * 180 / Double.pi
    /// Per orient hold, the wrist turns at most this far from where it started.
    public var orientFlexClamp = 35.0
    public var orientRollClamp = 60.0
    /// The commanded point more than this far from the arm stops the server (E-stop).
    public var trackingSafetyDistance = 0.10

    // MARK: One-shot commands

    public var moveStepLength: [String: Double] = ["fine": 0.005, "coarse": 0.020]
    public var moveTolerance: [String: Double] = ["fine": 0.002, "coarse": 0.005]
    /// A coarse move ramps over this many steps; a fine one over its share of it.
    public var coarseMoveSteps = 90
    /// Steps a move, joint move or gripper move may take past its ramp to settle before it fails.
    public var settleSteps = 90
    public var stableSteps = 5
    public var jointStep: [String: Double] = ["fine": 5, "coarse": 15]
    public var jointMoveSteps: [String: Int] = ["fine": 30, "coarse": 90]
    public var jointTolerance = 1.0
    /// Where the one-shot `gripper` command drives the jaws.
    public var gripperOpenTarget = 100.0
    public var gripperClosedTarget = 0.0
    public var gripperMoveSteps = 240
    public var gripperStableSteps = 10
    public var gripperOpenTolerance = 2.0
    public var gripperClosedBelow = 10.0
    /// A closing gripper that lags its target by this much for this many steps has met something.
    public var gripperContactLag = 1.0
    public var gripperContactSteps = 2
    public var gripperJogContactLag = 5.0
    public var gripperJogContactSteps = 5
    /// After contact the jaw target is set this far inside the measured angle, so the cube stays squeezed.
    public var gripperPreload = 0.25

    // MARK: Task

    /// The cube resting in the goal box, at most this fast, with the gripper reported open, for this many
    /// steps in a row is a success. The scene then shows it for `successDisplaySteps` and resets itself.
    public var successSteps = 30
    public var successDisplaySteps = 90
    public var successMaxSpeed = 0.02

    // MARK: Recorder

    /// Nil: the server was started without recording (`rec` is "none").
    public var recorder: Recorder?

    public struct Recorder: Equatable, Sendable {
        /// Demos already in the output file when the server started (it appends).
        public var savedAtStart: Int
        /// One sample every this many physics steps (30 a simulated second).
        public var stepsPerSample: Int

        public init(savedAtStart: Int = 0, stepsPerSample: Int = 2) {
            self.savedAtStart = savedAtStart
            self.stepsPerSample = stepsPerSample
        }
    }

    // MARK: Welcome

    public var coarseCentimetres = 2.0
    public var fineCentimetres = 0.5

    /// A pinch point fixed to a gripper that tilts with the arm's posture: it hangs `length` from the reported point,
    /// tilted away from the pan axis by an angle from straight down that changes with how far out from that axis and
    /// how high the reported point is, and sits `aside` to the left of the plane through the axis and the reported
    /// point, seen from the axis. With the wrist at its start pose, the simulator's gripper does this.
    public struct ToolTurn: Equatable, Sendable {
        /// The pan axis: where it meets the base's horizontal plane, base frame x and y.
        public var panAxis: SIMD2<Double>
        public var length: Double
        public var aside: Double
        /// The tilt from straight down, degrees, with the reported point `radiusAtStart` out from the pan axis and at
        /// `heightAtStart`.
        public var tiltAtStart: Double
        public var radiusAtStart: Double
        public var heightAtStart: Double
        /// How the tilt changes, radians per metre the reported point goes out from the pan axis, and up.
        public var tiltPerRadius: Double
        public var tiltPerHeight: Double

        public init(
            panAxis: SIMD2<Double>, length: Double, aside: Double, tiltAtStart: Double, radiusAtStart: Double,
            heightAtStart: Double, tiltPerRadius: Double, tiltPerHeight: Double
        ) {
            self.panAxis = panAxis
            self.length = length
            self.aside = aside
            self.tiltAtStart = tiltAtStart
            self.radiusAtStart = radiusAtStart
            self.heightAtStart = heightAtStart
            self.tiltPerRadius = tiltPerRadius
            self.tiltPerHeight = tiltPerHeight
        }

        /// The simulator's gripper near its reset pose, from its recorded states: at `armStart` the pinch point is the
        /// tool point it reports there, (33.2, −202.4, 87.8) mm, and for a small move of the reported point the pinch
        /// point goes about 1.5 times as far sideways, 1.6 times as far in height and a quarter as far outward. It
        /// holds to within a fraction of a millimetre a few centimetres out; farther away it is a model of how such an
        /// arm turns, not a measurement of this one.
        public static let s4Simulator = ToolTurn(
            panAxis: SIMD2(0.0207, -0.0231), length: 0.0945, aside: 0.01265, tiltAtStart: 40.15,
            radiusAtStart: 0.1183, heightAtStart: 0.16, tiltPerRadius: -10.27, tiltPerHeight: 10.02)

        /// Where the jaws pinch with the reported point at `arm`, base frame.
        public func pinch(_ arm: SIMD3<Double>) -> SIMD3<Double> {
            let out = SIMD2(arm.x, arm.y) - panAxis
            let radius = (out * out).sum().squareRoot()
            let away = out / radius
            let left = SIMD2(-away.y, away.x)
            let tilt =
                tiltAtStart * Double.pi / 180 + tiltPerRadius * (radius - radiusAtStart)
                + tiltPerHeight * (arm.z - heightAtStart)
            let across = away * (length * sin(tilt)) + left * aside
            return arm + SIMD3(across.x, across.y, -length * cos(tilt))
        }

        /// The height of the reported point over `place` (base frame x and y) at which the pinch point is at
        /// `pinchHeight`. The pinch point rises with the reported point at any place while `length` times
        /// `tiltPerHeight` is under one, so there is one such height.
        public func armHeight(over place: SIMD2<Double>, pinchAt pinchHeight: Double) -> Double {
            var low = pinchHeight - length, high = pinchHeight + length
            for _ in 0..<64 {
                let middle = (low + high) / 2
                if pinch(SIMD3(place.x, place.y, middle)).z < pinchHeight { low = middle } else { high = middle }
            }
            return (low + high) / 2
        }
    }

    public init() {}

    // MARK: Frames

    /// A world-frame position in the base frame.
    public func baseFromWorld(_ world: SIMD3<Double>) -> SIMD3<Double> {
        let shifted = world - baseInWorld
        return SIMD3(
            shifted.x * baseXInWorld.x + shifted.y * baseXInWorld.y + shifted.z * baseXInWorld.z,
            shifted.x * baseYInWorld.x + shifted.y * baseYInWorld.y + shifted.z * baseYInWorld.z,
            shifted.x * baseZInWorld.x + shifted.y * baseZInWorld.y + shifted.z * baseZInWorld.z)
    }

    /// A world-frame direction in the base frame: no shift.
    public func baseFromWorldDirection(_ world: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(
            world.x * baseXInWorld.x + world.y * baseXInWorld.y + world.z * baseXInWorld.z,
            world.x * baseYInWorld.x + world.y * baseYInWorld.y + world.z * baseYInWorld.z,
            world.x * baseZInWorld.x + world.y * baseZInWorld.y + world.z * baseZInWorld.z)
    }

    /// A base-frame position in the world frame.
    public func worldFromBase(_ base: SIMD3<Double>) -> SIMD3<Double> {
        baseXInWorld * base.x + baseYInWorld * base.y + baseZInWorld * base.z + baseInWorld
    }

    /// What a translation hold's offset moves the base by.
    public func baseFromLink(_ offset: SIMD3<Double>) -> SIMD3<Double> { offset * linkSigns }

    /// The base axis that lies along world z, and the way: `index` 0, 1 or 2 and `sign` 1 or -1.
    public var up: (index: Int, sign: Double) {
        let along = [baseXInWorld.z, baseYInWorld.z, baseZInWorld.z]
        let index = along.firstIndex { $0 != 0 } ?? 2
        return (index, along[index] < 0 ? -1 : 1)
    }

    /// One metre up, in the base frame.
    public var upVector: SIMD3<Double> { settingHeight(1, of: .zero) }

    /// How high a base-frame vector reaches: its part along world up.
    public func height(of base: SIMD3<Double>) -> Double { up.sign * base[up.index] }

    /// `base` moved along up until its height is `height`.
    public func settingHeight(_ height: Double, of base: SIMD3<Double>) -> SIMD3<Double> {
        var moved = base
        moved[up.index] = up.sign * height
        return moved
    }

    /// How far a base-frame vector reaches across the table: its length without the part along up.
    public func across(_ base: SIMD3<Double>) -> Double {
        let level = settingHeight(0, of: base)
        return (level * level).sum().squareRoot()
    }

    /// The pinch-turn model (`ToolTurn`) is written for a base whose z is up.
    var baseZIsUp: Bool { up.index == 2 && up.sign > 0 }

    /// The lab server's numbers as recorded on 2026-11-11: no cameras, no recording. Whether `state` carries the tool
    /// point is the model's own switch (`reportsToolPoint`, on here), not one of those numbers.
    public static let s4Simulator = ServerModelConfig()

    /// The same server, `stepsPerSecond` steps a wall second. `reportsToolPoint` false: `state` carries no tool point.
    public static func s4Simulator(
        stepsPerSecond: Double, recorder: Recorder? = nil, reportsToolPoint: Bool = true
    ) -> ServerModelConfig {
        var config = ServerModelConfig()
        config.stepsPerSecond = stepsPerSecond
        config.recorder = recorder
        config.reportsToolPoint = reportsToolPoint
        return config
    }
}
