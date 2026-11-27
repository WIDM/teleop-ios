import simd
import XCTest
@testable import TeleopCore

/// A tap whose reading reported the pinch point and told the gripper link starts a move that follows the measured
/// offset: it starts where any move starts, and each fresh reading takes half the offset's change off the link
/// command. A reading without both gives exactly the move it gave before the readings carried them.
final class GoingFollowTests: XCTestCase {
    typealias Rig = ArbiterRig

    /// The gate runs at the owner's tick.
    private let step = 1.0 / 30
    /// The arm at the box's centre, at the travel height.
    private let start = SIMD3(0.027617, -0.177418, Rig.travelZ)
    /// Inside the panel on a half in both schemes; it sends the arm 5.2 cm across, level.
    private let point = Rig.inPanel(0.3, 0.65)
    /// From the gripper link to the pinch point, about as the simulator reports it at its reset pose.
    private let offset = SIMD3(0.0125, -0.061, -0.072)

    /// A reading of the pinch point at `pinch`, with the gripper link `offset` away from it when one is given.
    private func reading(_ pinch: SIMD3<Double>, offset: SIMD3<Double>?, reported: Bool, age: Double = 0.1) -> ArmFix {
        ArmFix(pinch: pinch, ageS: age, holdPaused: false, gripper: offset.map { pinch - $0 }, pinchReported: reported)
    }

    /// A rig whose tap at `point` started a move from `fix`.
    private func going(from fix: ArmFix, file: StaticString = #filePath, line: UInt = #line) -> Rig {
        var rig = Rig(.screenTurns, assist: Rig.goTo())
        rig.facts = Rig.goFacts(arm: start)
        rig.facts.arm = fix
        XCTAssertEqual(rig.tap(1, at: point, after: 0.1), [.startTranslation], file: file, line: line)
        XCTAssertTrue(rig.isGoing, file: file, line: line)
        return rig
    }

    /// The first offset a following move asks for is the one any move asks for; after a fresh reading whose offset
    /// changed, the move asks for half that change less, in the link's frame, than the same move whose offset did not
    /// change.
    func testAReadingThatReportedThePinchPointStartsAMoveThatFollowsIt() throws {
        var plain = going(from: ArmFix(pinch: start, ageS: 0.1, holdPaused: false))
        var still = going(from: reading(start, offset: offset, reported: true))
        XCTAssertEqual(still.arbiter.goOffset(at: still.time), plain.arbiter.goOffset(at: plain.time))
        XCTAssertEqual(still.arbiter.goOffset(at: still.time), .zero, "it starts where the arm is")
        var turned = still

        // The gripper link where it was at the tap; the pinch point 0.2 mm to the side and 0.4 mm higher.
        let change = SIMD3(0.0002, 0, 0.0004)
        still.facts.arm = reading(start, offset: offset, reported: true)
        turned.facts.arm = reading(start + change, offset: offset + change, reported: true)
        XCTAssertEqual(still.wait(step), [])
        XCTAssertEqual(turned.wait(step), [])
        let a = try XCTUnwrap(still.arbiter.goOffset(at: still.time))
        let b = try XCTUnwrap(turned.arbiter.goOffset(at: turned.time))
        XCTAssertEqual(simd_distance(b - a, TestFrames.so101.link(fromBase: -change * 0.5)), 0, accuracy: 1e-12)
        plain.facts.arm = ArmFix(pinch: start, ageS: 0.1, holdPaused: false)
        XCTAssertEqual(plain.wait(step), [])
        XCTAssertEqual(
            simd_length(try XCTUnwrap(plain.arbiter.goOffset(at: plain.time + 0.5))),
            2 * simd_length(try XCTUnwrap(still.arbiter.goOffset(at: still.time + 0.5))), accuracy: 1e-12,
            "a following move sets off at half the speed")
    }

    /// The commands and the offsets of a whole move, the arm following the command, for readings that report the pinch
    /// point without the gripper link, or tell the gripper link of a pinch point the profile estimated: each call the
    /// same as for readings that carry neither.
    func testAReadingWithoutBothGivesTheMoveItGaveBefore() {
        let variants: [(String, (SIMD3<Double>, Double) -> ArmFix)] = [
            ("neither", { ArmFix(pinch: $0, ageS: $1, holdPaused: false) }),
            ("the gripper link of an estimate", { self.reading($0, offset: self.offset, reported: false, age: $1) }),
            ("a reported pinch point, no gripper link", { self.reading($0, offset: nil, reported: true, age: $1) }),
        ]
        var runs: [[[InputCommand]]] = []
        var offsets: [[SIMD3<Double>?]] = []
        for (name, fix) in variants {
            var rig = going(from: fix(start, 0.1))
            var history: [(at: TimeInterval, point: SIMD3<Double>)] = [(rig.time, start)]
            var commands: [[InputCommand]] = []
            var sent: [SIMD3<Double>?] = []
            while rig.isGoing && rig.time < 30 {
                let measured = rig.time + step - 0.1
                let arm = history.last { $0.at <= measured - 0.1 }?.point ?? start
                rig.facts.arm = fix(arm, 0.1)
                commands.append(rig.wait(step))
                sent.append(rig.arbiter.goOffset(at: rig.time))
                history.append((rig.time, rig.commanded(from: start) ?? arm))
            }
            XCTAssertEqual(commands.last, [.stopTranslation, .cue(.drive(.arrived))], name)
            runs.append(commands)
            offsets.append(sent)
        }
        XCTAssertEqual(runs[1], runs[0], variants[1].0)
        XCTAssertEqual(runs[2], runs[0], variants[2].0)
        XCTAssertEqual(offsets[1], offsets[0], variants[1].0)
        XCTAssertEqual(offsets[2], offsets[0], variants[2].0)
    }
}
