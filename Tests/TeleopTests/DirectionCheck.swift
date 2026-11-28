import simd
import TeleopCore
@testable import Teleop

/// The direction check: before the first move on a new arm, each of the six operator directions is pressed once for
/// about 1 cm through the app's real link, and the arm's position is read back from the server's own state. A direction
/// passes only when the arm went along the base axis the profile names for it, the way the profile says, by about the
/// distance asked and not sideways.
///
/// What it proves: that what the app sends (the profile's directions and link signs) and what the server does with it
/// agree. What it cannot prove: which way "forward" really points in the room. The app sends what the profile says, so
/// the arm always goes along the profile's forward axis; whether that is away from the operator is for a person to
/// see (docs/PROFILE.md, "Before the first move on a new arm").
enum DirectionCheck {
    /// How far the hold asks the target to go, metres.
    static let askedM = 0.01
    /// The least the arm may go along the named axis: half of what was asked.
    static let leastAlongM = 0.005
    /// The most it may go along it: half as far again as asked.
    static let mostAlongM = 0.015
    /// The most it may go along either of the other two axes.
    static let mostSidewaysM = 0.003

    /// What the arm did for one direction.
    struct Move {
        var direction: OperatorDirection
        /// The base axis the profile names for the direction.
        var expected: SignedAxis
        /// The arm's change of position in the base frame, metres, read from the server's state.
        var delta: SIMD3<Double>
    }

    /// Nil when the arm moved as the profile says; else one sentence naming the direction and the axis the arm went
    /// along instead.
    static func fault(_ move: Move) -> String? {
        let delta = move.delta
        let along = move.expected.component(of: delta)
        let name = move.direction.rawValue
        let said = "\(name) is base \(move.expected.text) in the profile"
        let cm = { (metres: Double) in String(format: "%.1f cm", abs(metres) * 100) }
        // The axis the arm went along most, and the way.
        let axis = BaseAxis.allCases.max { abs(delta[$0.index]) < abs(delta[$1.index]) } ?? .x
        let went = SignedAxis(axis, delta[axis.index] < 0 ? -1 : 1)
        if simd_length(delta) < leastAlongM {
            return "\(name): the arm did not move (\(said)); it went \(cm(simd_length(delta))). The hold did not reach "
                + "the server, or the arm was blocked."
        }
        if along < -leastAlongM || (went.axis == move.expected.axis && went.sign != move.expected.sign) {
            return "\(name): the arm went the wrong way: \(cm(delta[move.expected.axis.index])) along "
                + "base \(move.expected.reversed.text), where \(said). Check the sign of that axis in "
                + "`server.link_signs` and in `robot.directions`."
        }
        if went.axis != move.expected.axis {
            return "\(name): the arm went along base \(went.text) (\(cm(delta[axis.index]))) instead of base "
                + "\(move.expected.text) (\(cm(along)); \(said)). Check which axis `robot.directions` names for it."
        }
        if along < leastAlongM || along > mostAlongM {
            return "\(name): the arm went \(cm(along)) along base \(move.expected.text) where about "
                + "\(cm(askedM)) was asked (allowed \(cm(leastAlongM)) to \(cm(mostAlongM))). Check "
                + "`robot.motion.fine_mps` against the arm's real speed."
        }
        for other in BaseAxis.allCases where other != move.expected.axis && abs(delta[other.index]) > mostSidewaysM {
            return "\(name): the arm also went \(cm(delta[other.index])) along base "
                + "\(SignedAxis(other, delta[other.index] < 0 ? -1 : 1).text), more than \(cm(mostSidewaysM)) "
                + "(\(said)). Check `server.link_signs`."
        }
        return nil
    }
}

extension ScriptedOperator {
    /// Presses each of the six direction buttons once for about 1 cm on the Fine speed, with the arm clear, and returns
    /// what the server's state says the arm did for each. Needs the buttons mode: the pad is the one input that sends
    /// exactly one direction. Each direction is judged from the arm's position just before it, so the three pairs
    /// leave the arm where it was. Nil when the server's state could not be read.
    func directionMoves() -> [DirectionCheck.Move]? {
        precondition(mode == .buttons, "the direction check presses the pad's buttons")
        model.selectSpeed(.fine)
        let seconds = DirectionCheck.askedM / ButtonSpeed.fine.metresPerSecond(in: motion)
        var moves: [DirectionCheck.Move] = []
        pump(0.6)
        for button in [ButtonID.forward, .back, .left, .right, .up, .down] {
            step = "direction check, \(button.rawValue)"
            guard let direction = button.direction, let before = reportedArm(step) else { return nil }
            model.buttonDown(button)
            guard model.session.state.armMoving else {
                print("DIRECTION \(button.rawValue): hold did not start. log: \(model.debugLog.suffix(3))")
                model.buttonUp(button)
                return nil
            }
            _ = wait(seconds, until: { false })
            model.buttonUp(button)
            pump(2.0)
            guard let after = reportedArm(step) else { return nil }
            let delta = SIMD3<Double>(after - before)
            moves.append(.init(direction: direction, expected: frames.axis(for: direction), delta: delta))
            print(
                String(
                    format: "DIRECTION %@ (base %@): moved %+.1f %+.1f %+.1f cm", direction.rawValue,
                    frames.axis(for: direction).text, delta.x * 100, delta.y * 100, delta.z * 100))
        }
        return moves
    }

    /// The faults of the six moves, one sentence each; empty when every direction went as the profile says. Fails the
    /// test run's step when the state could not be read.
    func directionCheckFaults() -> [String]? {
        directionMoves().map { $0.compactMap(DirectionCheck.fault) }
    }
}
