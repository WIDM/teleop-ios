import simd
import TeleopCore
@testable import Teleop

/// The direction check: before the first move on a new arm, each of the six operator directions is pressed once for
/// about 1 cm through the app's real link, and the point the buttons drive is read back from the server's own state. A
/// direction passes when the arm went along the base axis the profile names for it, the way the profile says: the
/// move lies within 30 degrees of that axis. How far it went is a separate warning, never a failure.
///
/// What it proves: that what the app sends (the profile's directions and link signs) and what the server does with it
/// agree. What it cannot prove: which way "forward" really points in the room. The app sends what the profile says, so
/// the arm always goes along the profile's forward axis; whether that is away from the operator is for a person to
/// see (docs/PROFILE.md, "Before the first move on a new arm"). It adds a plausibility warning for that: the work box
/// should not lie clearly behind the base.
///
/// The check never resets the scene and never releases a stop: the operator brings the arm to a clear start pose first.
enum DirectionCheck {
    /// How far the hold asks the target to go, metres.
    static let askedM = 0.01
    /// Under this the arm did not move: a fault. Between this and `shortM` the move is a warning.
    static let leastMovedM = 0.002
    /// The usual range of the distance along the named axis, metres; outside it only a warning is given.
    static let shortM = 0.005
    static let longM = 0.015
    /// The most the move may lie off the named axis, degrees.
    static let withinDegrees = 30.0
    /// The work box's centre may lie behind the base by this share of the box's width along forward before the
    /// plausibility warning is given. An arm hung over its work area has the box's centre near the base.
    static let behindShare = 0.25

    /// The point a move is read from.
    enum Point: String {
        /// `ee_pos`: the gripper link's origin, which the server always reports.
        case gripperLink = "ee_pos"
        /// `tool_pos`: where the jaws pinch, which the app drives when the server reports it.
        case tool = "tool_pos"
    }

    /// What the arm did for one direction.
    struct Move {
        var direction: OperatorDirection
        /// The base axis the profile names for the direction.
        var expected: SignedAxis
        /// The point's change of position in the base frame, metres, read from the server's state.
        var delta: SIMD3<Double>
        /// False when the hold did not start, so the arm was not asked to move.
        var started = true
        var point = Point.gripperLink
    }

    /// What one run found: the moves up to the first fault (the run stops there), the faults (none or one) and the
    /// warnings.
    struct Result {
        var moves: [Move] = []
        var faults: [String] = []
        var warnings: [String] = []
    }

    private static func cm(_ metres: Double) -> String { String(format: "%.1f cm", abs(metres) * 100) }

    /// The angle between the move and the named axis, degrees: 0 along it the named way, 180 the other way.
    static func angleDegrees(_ move: Move) -> Double {
        let length = simd_length(move.delta)
        guard length > 0 else { return 90 }
        return acos(max(-1, min(1, move.expected.component(of: move.delta) / length))) * 180 / .pi
    }

    /// Nil when the arm moved as the profile says; else one sentence that begins with the direction and names a cause
    /// only as far as the move can tell it.
    static func fault(_ move: Move) -> String? {
        let delta = move.delta
        let along = move.expected.component(of: delta)
        let name = move.direction.rawValue
        let said = "\(name) is base \(move.expected.text) in the profile"
        guard move.started else {
            return
                "\(name): the hold did not start, so the arm was not asked to move (\(said)). A latched stop, an old "
                + "state or a refusal from the server can cause it; the check never releases a stop. Read the app's "
                + "log lines above, clear the stop yourself and run the check again."
        }
        // The axis the point went along most, and the way.
        let axis = BaseAxis.allCases.max { abs(delta[$0.index]) < abs(delta[$1.index]) } ?? .x
        let went = SignedAxis(axis, delta[axis.index] < 0 ? -1 : 1)
        if simd_length(delta) < leastMovedM {
            return "\(name): the arm did not move (\(said)); it went \(cm(simd_length(delta))). The server did not act "
                + "on the hold, or the arm was blocked at its start pose."
        }
        if angleDegrees(move) <= withinDegrees { return nil }
        if went.axis == move.expected.axis && went.sign != move.expected.sign {
            return "\(name): the arm went the wrong way: \(cm(delta[axis.index])) along "
                + "base \(move.expected.reversed.text), where \(said). Check the sign of that axis in "
                + "`server.link_signs`."
        }
        if went.axis != move.expected.axis {
            return "\(name): the arm went along base \(went.text) (\(cm(delta[axis.index]))) instead of base "
                + "\(move.expected.text) (\(cm(along)); \(said)). The server's frame has axes swapped, which a "
                + "profile cannot say: this arm's server needs code, not only a file."
        }
        let others = BaseAxis.allCases.filter { $0 != move.expected.axis }
        let other = others.max { abs(delta[$0.index]) < abs(delta[$1.index]) } ?? .x
        let otherAxis = SignedAxis(other, delta[other.index] < 0 ? -1 : 1)
        return "\(name): the arm went \(cm(along)) along base \(move.expected.text) but also \(cm(delta[other.index])) "
            + "along base \(otherAxis.text): \(Int(angleDegrees(move))) degrees off the axis, where up to "
            + "\(Int(withinDegrees)) is allowed (\(said)). A limit near the start pose, a sag under gravity or a path "
            + "that is not straight can cause it."
    }

    /// Nil when the move has the usual length; else a sentence about it. A warning never fails the check: the
    /// direction is right.
    static func warning(_ move: Move) -> String? {
        guard move.started, simd_length(move.delta) >= leastMovedM, angleDegrees(move) <= withinDegrees else {
            return nil
        }
        let along = move.expected.component(of: move.delta)
        guard along < shortM || along > longM else { return nil }
        return "\(move.direction.rawValue): the arm went \(cm(along)) along base \(move.expected.text), where about "
            + "\(cm(askedM)) was asked (usual \(cm(shortM)) to \(cm(longM))). The direction is right. Lag at the start of "
            + "a hold, a `robot.motion.fine_mps` that is not the arm's real speed on Fine, `robot.motion.tool_max_lead_m` "
            + "(the app's cap on a hold of the tool point) or a limit can cause it."
    }

    /// Nil when the work box does not lie clearly behind the base along forward; else a sentence. The box is measured
    /// in the base frame with no reference to `robot.directions`, and the operator stands behind the base facing the
    /// work area, so the box's centre less the base origin (0, 0, 0) should lie along forward and not along back.
    static func forwardWarning(_ profile: RobotProfile) -> String? {
        let low = SIMD3<Double>(profile.workspaceMin), high = SIMD3<Double>(profile.workspaceMax)
        let forward = profile.frames.forward
        let centre = forward.component(of: (low + high) / 2)
        let width = high[forward.axis.index] - low[forward.axis.index]
        guard centre < -behindShare * width else { return nil }
        return "forward is base \(forward.text) in the profile, but the work box's centre lies "
            + String(format: "%.1f cm", -centre * 100) + " behind the base along it, and the work area is usually in "
            + "front of the arm for an operator behind the base. If the operator stands that way, flip forward and "
            + "left in `robot.directions` (both together) and check again; if the work area is beside or behind the "
            + "base for this operator, ignore this."
    }
}

extension ScriptedOperator {
    /// Presses each of the six direction buttons once for about 1 cm on the Fine speed, with the arm clear, and reads
    /// back from the server's state what the point the buttons drive did: `tool_pos` when the server reports it, else
    /// `ee_pos`. Each move is judged as soon as it is read, and the run stops at the first fault. Needs the buttons
    /// mode: the pad is the one input that sends exactly one direction. Each direction is judged from the position just
    /// before it. It does not reset the scene or release a stop: it connects, reads and presses. Nil when the server's
    /// state could not be read.
    func directionCheck() -> DirectionCheck.Result? {
        precondition(mode == .buttons, "the direction check presses the pad's buttons")
        var result = DirectionCheck.Result()
        if let warning = DirectionCheck.forwardWarning(profile) {
            result.warnings.append(warning)
            print("DIRECTION WARNING \(warning)")
        }
        model.selectSpeed(.fine)
        let seconds = DirectionCheck.askedM / ButtonSpeed.fine.metresPerSecond(in: motion)
        pump(0.6)
        for button in [ButtonID.forward, .back, .left, .right, .up, .down] {
            step = "direction check, \(button.rawValue)"
            guard let direction = button.direction, let before = reportedControlledPoint(step) else { return nil }
            var move = DirectionCheck.Move(
                direction: direction, expected: frames.axis(for: direction), delta: .zero, point: before.kind)
            model.buttonDown(button)
            if model.session.state.armMoving {
                _ = wait(seconds, until: { false })
                model.buttonUp(button)
                pump(2.0)
                guard let after = reportedControlledPoint(step) else { return nil }
                move.delta = SIMD3<Double>(after.point - before.point)
            } else {
                print("DIRECTION \(button.rawValue): hold did not start. log: \(model.debugLog.suffix(3))")
                model.buttonUp(button)
                move.started = false
            }
            result.moves.append(move)
            print(
                String(
                    format: "DIRECTION %@ (base %@, %@): moved %+.1f %+.1f %+.1f cm", direction.rawValue,
                    move.expected.text, move.point.rawValue, move.delta.x * 100, move.delta.y * 100,
                    move.delta.z * 100))
            if let fault = DirectionCheck.fault(move) {
                result.faults.append(fault)
                return result
            }
            if let warning = DirectionCheck.warning(move) {
                result.warnings.append(warning)
                print("DIRECTION WARNING \(warning)")
            }
        }
        return result
    }
}
