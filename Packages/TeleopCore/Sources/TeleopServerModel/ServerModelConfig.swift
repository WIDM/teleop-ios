import Foundation

/// Every robot, task and protocol number the server model uses, in one place.
///
/// Unless a line says otherwise, a value is the S4 simulator server's own constant as it runs on the lab
/// machine (2026-11-11, with the local changes for state fields, capture start, reset keeping stops and
/// the watchdog keeping targets), or a value measured from recordings of it. Lengths are metres, angles degrees,
/// positions in the robot base frame unless the name ends in `World`.
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

    // MARK: Scene

    /// The robot base in the world frame. The server reports the arm in the base frame and objects in the world frame.
    public var baseInWorld = SIMD3<Double>(0, 0, 0.05)
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

    /// From the reported point to where the jaws pinch, base frame (the app's `RobotProfile.so101Simulator`).
    public var toolOffset = SIMD3<Double>(0.007, -0.036, -0.088)
    /// How close the pinch point must be to the cube's centre, across the table and in height, for closing
    /// the jaws to take hold of it (the app's `RobotProfile.graspTolerance`).
    public var graspToleranceAcross = 0.006
    public var graspToleranceHeight = 0.008
    /// The wrist and jaws after a reset, as measured. Roll 90 is jaws side by side, the grasp the tool offset is for;
    /// the published server starts at roll 0, jaws front to back.
    public var wristFlexStart = 40.24
    public var wristRollStart = 90.0
    public var jawStart = 0.0
    /// Model choice: the grasp works with the wrist roll within this of 90 (jaws side by side). Front to back,
    /// the real grasp lifted the cube 1 time in 16, so the model does not grasp at all.
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

    public init() {}

    /// The lab server as recorded on 2026-11-11: no cameras, no recording.
    public static let s4Simulator = ServerModelConfig()

    /// The same server, `stepsPerSecond` steps a wall second.
    public static func s4Simulator(stepsPerSecond: Double, recorder: Recorder? = nil) -> ServerModelConfig {
        var config = ServerModelConfig()
        config.stepsPerSecond = stepsPerSecond
        config.recorder = recorder
        return config
    }
}
