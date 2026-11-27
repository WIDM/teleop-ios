import Foundation

/// The model's deliberately small physical world.
///
/// The arm is one point, the one the server reports (the gripper link origin). It follows a commanded point
/// at a bounded distance per step and does not sag. Wrist and jaw angles are where their targets are, except
/// that closing jaws stop on a cube between them. The cube is grasped when the jaws close around it within the
/// measured tolerances, moves with the pinch point while held, and drops straight down when let go. The jaw tips
/// stop on the table; nothing else touches anything.
public struct World: Equatable, Sendable {
    /// The reported point, base frame.
    public internal(set) var arm: SIMD3<Double>
    /// Where the running Cartesian control is steering the arm.
    public internal(set) var command: SIMD3<Double>
    /// Wrist and jaw angles, degrees. The model's measured angle is its target.
    public internal(set) var wristFlex: Double
    public internal(set) var wristRoll: Double
    /// The jaw target (`held_gripper_target` in the server) and the measured jaw angle.
    public internal(set) var jawTarget: Double
    public internal(set) var jaw: Double
    /// Shoulder and elbow angles. Joint commands move them within their limits; the arm point ignores them.
    public internal(set) var armJoints: [String: Double]
    /// The cube's centre, world frame.
    public internal(set) var cube: SIMD3<Double>
    public internal(set) var holdingCube = false
    /// Cube centre minus pinch point when the jaws took hold of it.
    var gripOffset = SIMD3<Double>.zero
    /// How fast the cube moved in the last step, metres per simulated second.
    public internal(set) var cubeSpeed = 0.0
    /// The lowest the reported point can go because something the model does not simulate is under the jaws.
    /// Nil unless a test puts it there, as the conformance replay does where a recording shows the real jaws
    /// landing on the cube. A reset clears it.
    var obstacleUnderArm: Double?

    init(_ config: ServerModelConfig) {
        arm = config.armStart
        command = config.armStart
        wristFlex = config.wristFlexStart
        wristRoll = config.wristRollStart
        jawTarget = config.jawStart
        jaw = config.jawStart
        armJoints = config.armJointStart
        cube = config.cubeStartWorld
    }

    /// Where the jaws pinch, base frame.
    func pinch(_ config: ServerModelConfig) -> SIMD3<Double> { config.toolTurn?.pinch(arm) ?? arm + config.toolOffset }

    func cubeInBase(_ config: ServerModelConfig) -> SIMD3<Double> { config.baseFromWorld(cube) }

    /// Moves the arm toward `target` by at most `maxStep`, stopping its jaw tips (or a held cube) on the table.
    mutating func moveArm(toward target: SIMD3<Double>, maxStep: Double, _ config: ServerModelConfig) {
        var next = arm + limited(target - arm, to: maxStep)
        // Heights are along up, the base axis that lies along world z: the table's, over the base origin, is the
        // world's table height less the base's own height.
        let tableTop = config.tableTopWorld - config.baseInWorld.z
        var lowest: Double
        if let turn = config.toolTurn {
            // The pinch point's lowest height, and the height of the reported point that puts it there at this place.
            var pinchFloor = tableTop + config.jawReachBelowPinch
            if holdingCube {
                pinchFloor = max(pinchFloor, tableTop - config.height(of: gripOffset) + config.cubeSize / 2)
            }
            lowest = turn.armHeight(over: SIMD2(next.x, next.y), pinchAt: pinchFloor)
        } else {
            let toolHeight = config.height(of: config.toolOffset)
            lowest = tableTop - toolHeight + config.jawReachBelowPinch
            if holdingCube {
                lowest = max(lowest, tableTop - toolHeight - config.height(of: gripOffset) + config.cubeSize / 2)
            }
        }
        if let obstacleUnderArm { lowest = max(lowest, obstacleUnderArm) }
        next = config.settingHeight(max(config.height(of: next), lowest), of: next)
        arm = next
    }

    /// One physics step: jaws, grasp, carry and drop.
    mutating func settle(_ config: ServerModelConfig) {
        let before = cube
        let pinchPoint = pinch(config)
        if jawsAroundCube(config) && jawTarget < config.jawAngleOnCube {
            if !holdingCube {
                holdingCube = true
                gripOffset = cubeInBase(config) - pinchPoint
            }
            jaw = config.jawAngleOnCube
        } else {
            jaw = jawTarget
            holdingCube = false
        }
        if holdingCube {
            cube = config.worldFromBase(pinchPoint + gripOffset)
        } else {
            cube.z = restingHeight(config)
        }
        cubeSpeed = length(cube - before) / config.simStep
    }

    /// True when closing the jaws now holds the cube: already holding it, or open wider than it, side by side,
    /// near the start pitch, with the pinch point within the grasp tolerance of its centre.
    func jawsAroundCube(_ config: ServerModelConfig) -> Bool {
        if holdingCube { return true }
        let gap = cubeInBase(config) - pinch(config)
        return jaw >= config.jawAngleOnCube
            && config.across(gap) <= config.graspToleranceAcross
            && abs(config.height(of: gap)) <= config.graspToleranceHeight
            && abs(wristRoll - config.sidewaysRoll) <= config.sidewaysRollTolerance
            && abs(wristFlex - config.wristFlexStart) <= config.graspFlexTolerance
    }

    /// The cube's centre height when resting: on the table, or on the floor beside it.
    private func restingHeight(_ config: ServerModelConfig) -> Double {
        let onTable =
            cube.x >= config.tableMinWorld.x && cube.x <= config.tableMaxWorld.x
            && cube.y >= config.tableMinWorld.y && cube.y <= config.tableMaxWorld.y
        return (onTable ? config.tableTopWorld : 0) + config.cubeSize / 2
    }

    func cubeInGoal(_ config: ServerModelConfig) -> Bool {
        let gap = cube - config.goalWorld
        return abs(gap.x) <= config.goalHalfExtents.x + 1e-12 && abs(gap.y) <= config.goalHalfExtents.y + 1e-12
            && abs(gap.z) <= config.goalHalfExtents.z + 1e-12
    }
}

func length(_ vector: SIMD3<Double>) -> Double { (vector * vector).sum().squareRoot() }

/// `vector` shortened to at most `maximum` long.
func limited(_ vector: SIMD3<Double>, to maximum: Double) -> SIMD3<Double> {
    let size = length(vector)
    return size > maximum ? vector * (maximum / size) : vector
}

func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
    min(max(value, range.lowerBound), range.upperBound)
}

/// Rotation vector of an `[x, y, z, w]` quaternion, shortest angle, in radians.
func rotationVector(_ q: [Double]) -> SIMD3<Double> {
    guard q.count == 4 else { return .zero }
    let norm = (q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]).squareRoot()
    guard norm >= 1e-9 else { return .zero }
    var (x, y, z, w) = (q[0] / norm, q[1] / norm, q[2] / norm, q[3] / norm)
    if w < 0 { (x, y, z, w) = (-x, -y, -z, -w) }
    let size = (x * x + y * y + z * z).squareRoot()
    guard size >= 1e-9 else { return .zero }
    let angle = 2 * atan2(size, max(w, 0))
    return SIMD3(x, y, z) * (angle / size)
}
