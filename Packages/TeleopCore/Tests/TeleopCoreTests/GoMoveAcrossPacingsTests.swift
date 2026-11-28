import XCTest
import simd

@testable import TeleopCore

/// The numbers by which a going move follows the arm's pace run once per pacing: the SO-101's and bench arm B's
/// (`TestPacing`). Each case is built from the pacing's own numbers, a place just inside or just outside one of them,
/// and states what `GoMoveFollowTests` states for the SO-101: so what holds for B is what holds for the SO-101 with B's
/// numbers in it.
final class GoMoveAcrossPacingsTests: XCTestCase {
    private func limits(_ pacing: GoToPacing, corrections: Int = 2) -> GoToLimits {
        GoToLimits(
            travelHeightM: 0.05, speedMps: 0.04, arriveToleranceM: 0.008, corrections: corrections,
            correctionReachM: 0.03, settleS: 0.6, timeFactor: 1.5, allowanceS: 3, armDataTimeoutS: 2, startGraceS: 1.5,
            pacing: pacing)
    }

    /// The pinch point's travel height in the base frame: the profile's table, a `Float`, plus the travel height.
    private let travel = Double(Float(0.04)) + 0.05
    private var start: SIMD3<Double> { SIMD3(0.02, -0.20, travel + 0.03) }
    private var target: SIMD3<Double> { SIMD3(0.05, -0.20, travel) }
    private let tapOffset = SIMD3(0.0125, -0.061, -0.072)

    private func reading(gripper: SIMD3<Double>, offset: SIMD3<Double>, age: Double = 0.1) -> ArmFix {
        ArmFix(pinch: gripper + offset, ageS: age, holdPaused: false, gripper: gripper, pinchReported: true)
    }

    private func following(_ pacing: GoToPacing) -> GoMove {
        GoMove(
            frames: TestFrames.so101, start: start, target: target, limits: limits(pacing), at: 0, offset: tapOffset)
    }

    func testBenchBDiffersFromTheSO101InEveryPacingNumber() {
        let a = TestPacing.so101, b = TestPacing.benchB
        XCTAssertNotEqual(a.followShare, b.followShare)
        XCTAssertNotEqual(a.paceGain, b.paceGain)
        XCTAssertNotEqual(a.slowestShare, b.slowestShare)
        XCTAssertNotEqual(a.startShare, b.startShare)
        XCTAssertNotEqual(a.pathWatchTolerances, b.pathWatchTolerances)
        XCTAssertNotEqual(a.freshMs, b.freshMs)
        XCTAssertNotEqual(a.stillM, b.stillM)
        XCTAssertNotEqual(a.paceChangeShare, b.paceChangeShare)
    }

    /// A following move starts at the start share of the speed, and its time limit has room for that.
    func testAFollowingMoveStartsAtTheStartShareOfTheSpeed() {
        for (name, pacing) in TestPacing.all {
            let plain = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits(pacing), at: 0)
            let move = following(pacing)
            XCTAssertEqual(
                simd_distance(move.commanded(at: 0.5), start), 0.04 * pacing.startShare * 0.5, accuracy: 1e-12, name)
            let path = 0.03 + 0.03
            XCTAssertEqual(
                move.deadline - plain.deadline, path / 0.04 * (1 / pacing.startShare - 1) * 1.5,
                accuracy: 1e-9, name)
        }
    }

    /// Each fresh reading takes the follow share of the offset's change off the link command.
    func testEachFreshReadingTakesTheFollowShareOfTheOffsetsChangeOffTheLinkCommand() {
        for (name, pacing) in TestPacing.all {
            var move = following(pacing)
            let gripper = start - tapOffset + SIMD3(0, 0, -0.001)
            let change = SIMD3(0.0002, 0, 0.0004)
            XCTAssertNil(move.observe(reading(gripper: gripper, offset: tapOffset + change), at: 0.2), name)
            let planned = TestFrames.so101.link(fromBase: move.commanded(at: 0.2) - start)
            let sent = move.linkOffset(at: 0.2)
            XCTAssertEqual(
                simd_distance(sent - planned, TestFrames.so101.link(fromBase: -change * pacing.followShare)), 0,
                accuracy: 1e-12, name)
        }
    }

    /// The pace after a second reading: the command's step over 0.1 s, as a share of the speed, with `swing` metres of
    /// the offset's turn for each metre the link travelled over `travelled` metres of travel.
    private func paceShare(_ pacing: GoToPacing, swing: Double, travelled: Double) -> Double {
        var move = following(pacing)
        let gripper0 = start - tapOffset
        XCTAssertNil(move.observe(reading(gripper: gripper0, offset: tapOffset), at: 0.1))
        let gripper1 = gripper0 + SIMD3(0, 0, -travelled)
        XCTAssertNil(
            move.observe(reading(gripper: gripper1, offset: tapOffset + SIMD3(swing * travelled, 0, 0)), at: 0.4))
        return simd_distance(move.commanded(at: 0.5), move.commanded(at: 0.4)) / (0.04 * 0.1)
    }

    /// The command moves at min(1, pace gain over the swing) of the speed, never under the slowest share.
    func testTheCommandMovesAtThePaceGainOverTheSwingBetweenTheSlowestShareAndAll() {
        for (name, pacing) in TestPacing.all {
            let travelled = 1.2 * pacing.stillM
            let middle = 0.8
            // A swing slow enough to need the slowest share: gain over it is under the slowest share. The offset turns
            // by swing times the travel, which stays inside the path watch's reach.
            let slow = 1.2 * pacing.paceGain / pacing.slowestShare
            for swing in [slow, pacing.paceGain / middle, pacing.paceGain / 4] {
                let expected = min(1, max(pacing.slowestShare, pacing.paceGain / swing))
                XCTAssertEqual(
                    paceShare(pacing, swing: swing, travelled: travelled), expected, accuracy: 1e-9, "\(name) \(swing)")
            }
        }
    }

    /// The pace is set again only when the share it would move at differs from the present one by more than the pace
    /// change share of the present one.
    func testThePaceChangesOnlyBeyondThePaceChangeShare() {
        for (name, pacing) in TestPacing.all {
            let travelled = 1.2 * pacing.stillM
            for (factor, changes) in [
                (1 + 0.9 * pacing.paceChangeShare, false), (1 + 1.1 * pacing.paceChangeShare, true),
                (1 - 0.9 * pacing.paceChangeShare, false), (1 - 1.1 * pacing.paceChangeShare, true),
            ] {
                let share = pacing.startShare * factor
                XCTAssertGreaterThanOrEqual(share, pacing.slowestShare, name)
                let measured = paceShare(pacing, swing: pacing.paceGain / share, travelled: travelled)
                XCTAssertEqual(measured, changes ? share : pacing.startShare, accuracy: 1e-9, "\(name) \(factor)")
            }
        }
    }

    /// A pace is measured only over the still distance of link travel or more.
    func testThePaceIsMeasuredOnlyOverTheStillDistanceOfLinkTravel() {
        for (name, pacing) in TestPacing.all {
            let slow = 1.2 * pacing.paceGain / pacing.slowestShare
            XCTAssertEqual(
                paceShare(pacing, swing: slow, travelled: 0.9 * pacing.stillM), pacing.startShare, accuracy: 1e-9, name)
            XCTAssertEqual(
                paceShare(pacing, swing: slow, travelled: 1.1 * pacing.stillM), pacing.slowestShare, accuracy: 1e-9,
                name)
        }
    }

    /// A fresh reading this many arrive tolerances from the leg ahead ends the move stopped short.
    func testAReadingBeyondThePathWatchTolerancesEndsTheMoveStoppedShort() {
        for (name, pacing) in TestPacing.all {
            let beyond = pacing.pathWatchTolerances * 0.008
            for (share, ends) in [(0.95, false), (1.05, true)] {
                var move = following(pacing)
                let gripper = start - tapOffset + SIMD3(0, beyond * share, 0)
                let verdict = move.observe(reading(gripper: gripper, offset: tapOffset), at: 0.2)
                XCTAssertEqual(verdict, ends ? .stoppedShort : nil, "\(name) \(share)")
            }
        }
    }

    /// A following move waits while its newest reading is older than the pacing's freshness, and goes on while it is
    /// fresher.
    func testAFollowingMoveWaitsOnlyForAReadingOlderThanItsFreshness() {
        let levelStart = SIMD3(0.0, -0.2, 0.09), levelTarget = SIMD3(0.05, -0.2, 0.09)
        let down = SIMD3(0.0, 0.0, -0.08)
        for (name, pacing) in TestPacing.all {
            let freshS = Double(pacing.freshMs) / 1000
            for (share, waits) in [(0.9, false), (1.1, true)] {
                var move = GoMove(
                    frames: TestFrames.so101, start: levelStart, target: levelTarget, limits: limits(pacing), at: 0,
                    offset: down)
                func fix(_ pinch: SIMD3<Double>, age: Double) -> ArmFix {
                    ArmFix(pinch: pinch, ageS: age, holdPaused: false, gripper: pinch - down, pinchReported: true)
                }
                XCTAssertNil(move.observe(fix(levelStart, age: 0.1 * freshS), at: 0.1), name)
                XCTAssertNil(move.observe(fix(move.commanded(at: 0.8), age: 0.1 * freshS), at: 1.0), name)
                XCTAssertNil(move.observe(fix(move.commanded(at: 0.8), age: freshS * share), at: 1.4), name)
                let held = move.commanded(at: 1.4)
                XCTAssertEqual(move.commanded(at: 2.4) == held, waits, "\(name) \(share)")
            }
        }
    }

    /// Standing still is within the still distance of where the arm stood: a settle short of the target is judged from
    /// readings that far apart in place.
    func testAnArmCountsAsStandingStillWithinTheStillDistance() {
        let levelStart = SIMD3(0.0, -0.2, 0.09), levelTarget = SIMD3(0.05, -0.2, 0.09)
        for (name, pacing) in TestPacing.all {
            for (share, stoppedShort) in [(0.9, true), (1.1, false)] {
                var move = GoMove(
                    frames: TestFrames.so101, start: levelStart, target: levelTarget,
                    limits: limits(pacing, corrections: 0), at: 0)
                func fix(_ pinch: SIMD3<Double>) -> ArmFix { ArmFix(pinch: pinch, ageS: 0.1, holdPaused: false) }
                XCTAssertNil(move.observe(fix(levelStart), at: 0.1), "\(name): the corner")
                // Long after the leg's command has ended and the start's grace is over: the first reading anchors a
                // settle, the second, 0.7 s later, is within the still distance of it or not.
                XCTAssertNil(move.observe(fix(levelStart), at: 3.0), name)
                let verdict = move.observe(fix(levelStart + SIMD3(pacing.stillM * share, 0, 0)), at: 3.7)
                XCTAssertEqual(verdict, stoppedShort ? .stoppedShort : nil, "\(name) \(share)")
            }
        }
    }
}
