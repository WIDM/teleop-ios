import simd
import TeleopCore
import TeleopServerModel
@testable import Teleop

/// The in-app server model set up as bench arm B's server: a configuration built from B's profile file and B's scene,
/// for the tests that drive the app against it. Nothing here is shipped.
///
/// Everything the profile also says (where the base hangs and how it is turned, how the link is signed, the pinch
/// offset, the work box, the table's height, the sizes, the grasp tolerance, the stop distance, the wrist and jaw at
/// the start) is read from the profile, so the model and the app cannot describe two different arms. What only a server
/// knows, the places of the table, the object and the goal in the world, is B's scene below.
enum BenchArmB {
    /// B's scene in the world frame, metres: where the table lies and where the object and the goal sit on it. The table
    /// top is 12 cm over the world floor, 28 cm under the base. The goal lies 6 cm to one side of the object and 3 cm
    /// farther on, so the carry is across and forward for B's operator, not the SO-101's single sideways move.
    enum Scene {
        static let tableMinAcross = SIMD2<Double>(-0.10, -0.40)
        static let tableMaxAcross = SIMD2<Double>(0.20, -0.10)
        static let objectAcross = SIMD2<Double>(0.03, -0.25)
        static let goalAcross = SIMD2<Double>(0.09, -0.22)
        /// How far the goal's box reaches above and below the object's resting height, and how far above the object's
        /// resting centre the goal's centre lies.
        static let goalHalfHeight = 0.02
        static let goalCentreAbove = 0.001
    }

    /// The server model as B's server: `steps` physics steps a second (8 for B, a slow loop with its cameras on), each
    /// covering a real eighth of a second.
    static let stepsPerSecond = 8.0

    enum Fault: Error { case notALinearJaw, unevenWorkBox }

    /// The model for `profile`. Throws when the profile is not one the model can stand in for: its jaw must read a gap in
    /// millimetres, and its work box must reach the same distance every way from the arm's start (a profile's up is already
    /// the world's up).
    static func config(
        for profile: RobotProfile = TestProfiles.benchB, recorder: ServerModelConfig.Recorder? = nil,
        reportsToolPoint: Bool = true
    ) throws -> ServerModelConfig {
        guard profile.gripper.unit == .mm else { throw Fault.notALinearJaw }
        let frames = profile.frames
        var config = try ServerModelConfig().settingFrames(from: frames)
        config.stepsPerSecond = stepsPerSecond
        config.recorder = recorder
        config.reportsToolPoint = reportsToolPoint

        // The pinch offset and where the arm starts: the middle of the work box (the pinch point's) less the offset.
        config.toolOffset = SIMD3<Double>(profile.toolOffset)
        let low = SIMD3<Double>(profile.workspaceMin), high = SIMD3<Double>(profile.workspaceMax)
        let half = (high - low) / 2
        guard abs(half.x - half.y) < 1e-6, abs(half.y - half.z) < 1e-6 else { throw Fault.unevenWorkBox }
        config.workspaceHalfSize = half.x
        config.armStart = (low + high) / 2 - config.toolOffset
        config.trackingSafetyDistance = profile.server.stopDistanceM

        // The scene: the sizes and the table's height from the profile, the places from B's scene.
        config.cubeSize = Double(profile.targetSize)
        config.tableTopWorld = frames.baseInWorld.z + Double(profile.tableHeight)
        config.tableMinWorld = Scene.tableMinAcross
        config.tableMaxWorld = Scene.tableMaxAcross
        let resting = config.tableTopWorld + config.cubeSize / 2
        config.cubeStartWorld = SIMD3(Scene.objectAcross.x, Scene.objectAcross.y, resting)
        config.goalWorld = SIMD3(Scene.goalAcross.x, Scene.goalAcross.y, resting + Scene.goalCentreAbove)
        let goalHalf = Double(profile.goalSize) / 2
        config.goalHalfExtents = SIMD3(goalHalf, goalHalf, Scene.goalHalfHeight)
        config.graspToleranceAcross = Double(profile.graspTolerance.x)
        config.graspToleranceHeight = Double(profile.graspTolerance.y)

        // The wrist at the start, where the pinch offset was measured: the jaws side by side for B is roll 0.
        config.wristFlexStart = profile.offsetMeasuredFlexDeg
        config.wristRollStart = profile.offsetMeasuredRollDeg
        config.sidewaysRoll = profile.offsetMeasuredRollDeg

        // A linear jaw: the reading is the gap between the pads in millimetres, so closing on the object stops at its
        // width, and every jaw rate and distance of the model (made for a jaw in degrees, 100 open) scales with the gap.
        let jaw = profile.gripper
        let scale = (jaw.openReading - jaw.closedReading) / 100
        config.jawStart = jaw.closedReading
        config.jawLimits = jaw.closedReading...jaw.openReading
        config.gripperOpenTarget = jaw.openReading
        config.gripperClosedTarget = jaw.closedReading
        config.jawAngleOnCube = config.cubeSize * 1000
        config.poseJawRange *= scale
        config.poseJawOpenRate *= scale
        config.poseJawCloseRate *= scale
        for key in config.gripperJogOpenRate.keys { config.gripperJogOpenRate[key]! *= scale }
        for key in config.gripperJogCloseRate.keys { config.gripperJogCloseRate[key]! *= scale }
        config.gripperClosedBelow *= scale
        config.gripperOpenTolerance *= scale
        config.gripperContactLag *= scale
        config.gripperJogContactLag *= scale
        config.gripperPreload *= scale

        // A step covers a real eighth of a second where the SO-101 model's covers a sixtieth of one: what the arm and the
        // wrist may move in a step grows in the same share, so B's arm is as quick as the model's usual one.
        let share = config.simStep * stepsPerSecond
        config.simStep = 1 / stepsPerSecond
        config.armStepInPose *= 1 / share
        config.armStepInJog *= 1 / share
        config.wristStepPerStep *= 1 / share
        // The counts of steps are times: a reset, a success on show, a move's ramp and a contact each last as long in
        // seconds as the SO-101 model's, so they take the same share fewer steps (never none).
        func steps(_ count: Int) -> Int { max(Int((Double(count) * share).rounded()), 1) }
        config.resetSteps = steps(config.resetSteps)
        config.successSteps = steps(config.successSteps)
        config.successDisplaySteps = steps(config.successDisplaySteps)
        config.coarseMoveSteps = steps(config.coarseMoveSteps)
        config.settleSteps = steps(config.settleSteps)
        config.stableSteps = steps(config.stableSteps)
        config.jointMoveSteps = config.jointMoveSteps.mapValues(steps)
        config.gripperMoveSteps = steps(config.gripperMoveSteps)
        config.gripperStableSteps = steps(config.gripperStableSteps)
        config.gripperContactSteps = steps(config.gripperContactSteps)
        config.gripperJogContactSteps = steps(config.gripperJogContactSteps)
        return config
    }
}
