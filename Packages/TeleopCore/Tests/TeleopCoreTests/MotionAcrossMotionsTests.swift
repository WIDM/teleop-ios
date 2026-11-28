import XCTest
import simd

@testable import TeleopCore

/// The rules that take the profile's motion and server facts run once per profile: the SO-101 and bench arm B
/// (`TestMotion`, `TestServer`). Each expectation is derived from the profile's own numbers, so what holds for B is what
/// holds for the SO-101 with B's numbers in it.
final class MotionAcrossMotionsTests: XCTestCase {
    func testBenchBDiffersFromTheSO101InTheNumbersTheRulesRead() {
        let a = TestMotion.so101, b = TestMotion.benchB
        XCTAssertNotEqual(a.fineMps, b.fineMps)
        XCTAssertNotEqual(a.coarseMps, b.coarseMps)
        XCTAssertNotEqual(a.maxLeadM, b.maxLeadM)
        XCTAssertNotEqual(TestServer.so101.stopDistanceM, TestServer.benchB.stopDistanceM)
        XCTAssertNotEqual(TestServer.so101.resync, TestServer.benchB.resync)
        for (_, motion, server) in zip(TestMotion.all, TestServer.all).map({ ($0.0.name, $0.0.motion, $0.1.server) }) {
            XCTAssertLessThan(Double(motion.maxLeadM), server.stopDistanceM)
            XCTAssertLessThan(Double(motion.toolMaxLeadM), server.stopDistanceM)
        }
    }

    /// A held button's target moves at the profile's speed for the chosen switch, along the axis its direction names.
    func testAButtonRampMovesAtTheProfilesSpeed() {
        for (name, motion) in TestMotion.all {
            for speed in ButtonSpeed.allCases {
                let perSecond = speed == .fine ? motion.fineMps : motion.coarseMps
                XCTAssertEqual(speed.metresPerSecond(in: motion), perSecond, name)
                for direction in OperatorDirection.allCases {
                    let ramp = ButtonRamp(
                        direction: direction, speed: speed, startMs: 100, frames: TestFrames.so101, motion: motion)
                    XCTAssertEqual(ramp.distance(atMs: 100), 0, accuracy: 1e-12, "\(name) \(direction) at the press")
                    for ms in [600, 1_100, 4_100] {
                        XCTAssertEqual(
                            ramp.distance(atMs: ms), perSecond * Double(ms - 100) / 1000, accuracy: 1e-12,
                            "\(name) \(speed) \(direction) at \(ms)")
                    }
                    XCTAssertEqual(
                        simd_length(ramp.offset(atMs: 2_100)), 2 * perSecond, accuracy: 1e-12, "\(name) \(direction)")
                }
            }
        }
    }

    /// A frozen ramp stops where it is, whatever its speed.
    func testAFrozenRampStopsAtItsSpeedsDistance() {
        for (name, motion) in TestMotion.all {
            var ramp = ButtonRamp(
                direction: .forward, speed: .coarse, startMs: 0, frames: TestFrames.so101, motion: motion)
            ramp.freeze(atMs: 500)
            XCTAssertEqual(ramp.distance(atMs: 3_000), motion.coarseMps * 0.5, accuracy: 1e-12, name)
        }
    }

    /// A pad sitting: the offset each tick asks for is the profile's speed times the hold's age, and a speed switch made
    /// between holds takes effect on the next hold.
    func testAPadSittingAsksForTheProfilesSpeed() {
        for (name, motion) in TestMotion.all {
            var pad = ButtonArbiter(frames: TestFrames.so101, motion: motion)
            XCTAssertEqual(pad.motion, motion)
            _ = pad.press(.forward, atMs: 1_000, gripping: false)
            XCTAssertEqual(offsetLength(pad.tick(atMs: 2_000)), motion.coarseMps, accuracy: 1e-12, name)
            _ = pad.release(.forward)
            XCTAssertEqual(pad.selectSpeed(.fine), [.speedChanged(.fine)])
            _ = pad.press(.forward, atMs: 5_000, gripping: false)
            XCTAssertEqual(offsetLength(pad.tick(atMs: 7_000)), 2 * motion.fineMps, accuracy: 1e-12, name)
        }
    }

    private func offsetLength(_ commands: [ButtonCommand]) -> Double {
        guard case .updateTranslation(let offset)? = commands.first else {
            XCTFail("no update in \(commands)")
            return .nan
        }
        return simd_length(offset)
    }

    /// While the jaws hold an object a server that lifts badly through the tool point is driven by the gripper link; a
    /// server that lifts fine through it keeps the tool point, held or not.
    func testTheHeldObjectPointDecidesThePathOfAPadHold() {
        for point in HeldObjectPoint.allCases {
            var hold = ObjectHold(heldObjectPoint: point)
            let free = hold.padHoldPath(toolCalibrated: true, coordinatedHeight: true, vertical: true)
            XCTAssertEqual(free, PadHoldPath(useToolPoint: true, toolMotion: .coordinatedHeight), "\(point)")
            hold.apply(.contactReported)
            let held = hold.padHoldPath(toolCalibrated: true, coordinatedHeight: true, vertical: true)
            switch point {
            case .gripperLink: XCTAssertEqual(held, PadHoldPath(useToolPoint: false, toolMotion: nil), "\(point)")
            case .toolPoint: XCTAssertEqual(held, free, "\(point)")
            }
            XCTAssertTrue(hold.holding, "holding is a fact either way: \(point)")
        }
    }
}
