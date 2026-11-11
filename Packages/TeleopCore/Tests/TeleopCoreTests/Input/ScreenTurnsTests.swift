import XCTest
@testable import TeleopCore

/// Scheme A, "Screen turns": one test per row of §2.4.
final class ScreenTurnsTests: XCTestCase {
    typealias Rig = ArbiterRig

    func testA1VolUpStartsTranslation() {
        var rig = Rig(.screenTurns)
        XCTAssertEqual(rig.press(.upper), [.startTranslation])
        XCTAssertEqual(rig.phase(.key(.upper)), .engaged(.translation))
    }

    func testA1RefusedWithTheReasonGiven() {
        var rig = Rig(.screenTurns)
        rig.facts.refusal = .noLink
        XCTAssertEqual(rig.press(.upper), [.cue(.refused(.noLink))])
        XCTAssertEqual(rig.phase(.key(.upper)), .dead)
        XCTAssertEqual(rig.release(.upper), [])

        rig.facts = InputFacts(trackingRefusal: .notTracking, translationRefusal: .posture)
        XCTAssertEqual(rig.press(.upper, after: 1), [.cue(.refused(.notTracking))])
        rig.release(.upper)
        rig.facts = InputFacts(translationRefusal: .posture)
        XCTAssertEqual(rig.press(.upper, after: 1), [.cue(.refused(.posture))])
    }

    func testA1rVolUpEndedStopsTranslation() {
        var rig = Rig(.screenTurns)
        rig.press(.upper)
        XCTAssertEqual(rig.release(.upper, after: 0.5), [.stopTranslation])
        XCTAssertNil(rig.arbiter.engagedHold)
    }

    func testA2VolDownStartsClosing() {
        var rig = Rig(.screenTurns)
        // Closing needs no phone tracking.
        rig.facts.trackingRefusal = .notTracking
        XCTAssertEqual(rig.press(.lower), [.startGripper(.closed)])
    }

    func testA2gVolDownWhileGrippingIsRefusedWithEnd() {
        var rig = Rig(.screenTurns)
        rig.facts.gripping = true
        XCTAssertEqual(rig.press(.lower), [.cue(.alreadyGripping)])
        XCTAssertEqual(rig.release(.lower, after: 0.3), [])
        // The gripping flag is a fact: once a reset clears it, close works again.
        rig.facts.gripping = false
        XCTAssertEqual(rig.press(.lower, after: 1), [.startGripper(.closed)])
    }

    func testA2rVolDownEndedStopsTheGripper() {
        var rig = Rig(.screenTurns)
        rig.press(.lower)
        XCTAssertEqual(rig.release(.lower, after: 0.4), [.stopGripper])
    }

    func testA3AValidTouchIsUndecidedAndSilent() {
        var rig = Rig(.screenTurns)
        XCTAssertEqual(rig.touchDown(1, at: Rig.middle), [])
        XCTAssertEqual(rig.phase(.touch(1)), .waiting)
        XCTAssertNil(rig.arbiter.engagedHold)
    }

    func testA3dATouchThatBeginsWhileEngagedIsDeadAndCuesOnlyAtACommitThreshold() {
        var rig = Rig(.screenTurns)
        rig.press(.upper)
        XCTAssertEqual(rig.touchDown(1, at: Rig.middle), [])
        XCTAssertEqual(rig.phase(.touch(1)), .dead)
        // Below the threshold: silent.
        XCTAssertEqual(rig.slide(1, mm: 9, degrees: 90, dt: 0.02), [])
        XCTAssertEqual(rig.slide(1, mm: 1, degrees: 90), [.cue(.dead)])
        XCTAssertEqual(rig.slide(1, mm: 10, degrees: 90), [], "NO once")
        rig.lift(1)

        // A dead touch whose turn would have committed cues too, once the palm window is over.
        rig.touchDown(2, at: Rig.middle, after: 0.1)
        XCTAssertEqual(rig.rotate(turn: 8, steps: 3, dt: 0.02), [])
        XCTAssertEqual(rig.wait(0.05), [.cue(.dead)])
        rig.lift(2)
        rig.orient(turn: 0)

        // A dead touch that slides sideways never would have committed: silent, and it stops owing NO.
        rig.touchDown(3, at: Rig.middle, after: 0.1)
        XCTAssertEqual(rig.slide(3, mm: 12, degrees: 0, dt: 0.02), [])
        XCTAssertEqual(rig.slide(3, mm: 15, degrees: 90), [])
        XCTAssertEqual(rig.release(.upper), [.stopTranslation])
    }

    func testA4ASlideUpOpensAtTenMillimetres() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.middle)
        rig.wait(0.1)
        XCTAssertEqual(rig.slide(1, mm: 9, degrees: 90), [])
        XCTAssertEqual(rig.slide(1, mm: 1, degrees: 90), [.startGripper(.open)])
        XCTAssertEqual(rig.phase(.touch(1)), .engaged(.gripper(.open)))
        // Further sliding, any way, changes nothing.
        XCTAssertEqual(rig.slide(1, mm: 30, degrees: 200), [])
        XCTAssertEqual(rig.rotate(turn: 20), [])
    }

    func testA4NothingCommitsInsideThePalmWindow() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.middle)
        // 12 mm up within 60 ms: judged when the window ends, because it still holds.
        XCTAssertEqual(rig.slide(1, mm: 12, degrees: 90, dt: 0.005), [])
        XCTAssertEqual(rig.wait(0.039), [])
        XCTAssertEqual(rig.wait(0.001), [.startGripper(.open)])

        // A slide that came back under 10 mm before the window ended does nothing then.
        rig.lift(1, after: 0.2)
        rig.touchDown(2, at: Rig.middle, after: 0.2)
        rig.slide(2, mm: 11, degrees: 90, dt: 0.004)
        rig.slide(2, mm: 4, degrees: 270, dt: 0.004)
        XCTAssertEqual(rig.wait(0.1), [])
        XCTAssertEqual(rig.phase(.touch(2)), .waiting)
    }

    func testA4bAnUpwardSlideWithAnUnclearTurnIsDead() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.middle)
        rig.wait(0.1)
        // Turned and tilted 6° each: neither dominates.
        XCTAssertEqual(rig.rotate(turn: 6, tilt: 6), [])
        XCTAssertEqual(rig.slide(1, mm: 10, degrees: 90), [.cue(.dead)])
        XCTAssertEqual(rig.phase(.touch(1)), .dead)
        XCTAssertEqual(rig.rotate(turn: 20, tilt: 0), [])
    }

    func testA5ASideOrDownwardSlideIsDead() {
        for degrees in [0.0, 180, 270, 30, 150, 300] {
            var rig = Rig(.screenTurns)
            rig.touchDown(1, at: Rig.middle)
            rig.wait(0.1)
            XCTAssertEqual(rig.slide(1, mm: 15, degrees: degrees), [.cue(.dead)], "\(degrees)°")
            XCTAssertEqual(rig.slide(1, mm: 20, degrees: 90), [])
        }
    }

    func testA5AnExactDiagonalIsNotUp() {
        // |dy| > |dx| is strict: a slide exactly up and to the side is dead.
        for dx in [-64.0, 64] {
            var rig = Rig(.screenTurns)
            rig.touchDown(1, at: Rig.middle)
            rig.wait(0.1)
            XCTAssertEqual(rig.move(1, to: Rig.middle + SIMD2(dx, -64)), [.cue(.dead)])
        }
    }

    func testA6ADominantTurnCommitsTheWrist() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.middle)
        rig.wait(0.1)
        XCTAssertEqual(rig.rotate(turn: 4.9, tilt: 1), [])
        let commands = rig.orient(turn: 5)
        XCTAssertEqual(commands.withoutUpdates, [.startWrist])
        XCTAssertEqual(commands.wristTargets.count, 1)
        // The committing 5° count.
        XCTAssertEqual(commands.wristTargets.first?.axis, .turn)
        XCTAssertEqual(commands.wristTargets.first?.degrees ?? 0, 5, accuracy: 1e-9)
        XCTAssertEqual(rig.phase(.touch(1)), .engaged(.wrist))
        // Mixed rotation afterwards still moves one axis only.
        var later = rig.rotate(turn: 20, tilt: 15, steps: 30).wristTargets
        for _ in 0..<10 { later += rig.orient(after: 1.0 / 60).wristTargets }
        XCTAssertTrue(later.allSatisfy { $0.axis == .turn })
        XCTAssertEqual(later.last!.degrees, 20, accuracy: 0.01)
    }

    func testA6ADominantTiltCommitsTheWristAndRespectsTheClamp() {
        var rig = Rig(.screenTurns, constants: InputConstants(tiltSign: -1))
        rig.touchDown(1, at: Rig.middle)
        rig.wait(0.1)
        let commands = rig.rotate(tilt: 30, steps: 30)
        XCTAssertEqual(commands.withoutUpdates, [.startWrist, .cue(.limit)])
        XCTAssertEqual(commands.wristTargets.first!, WristTarget(axis: .tilt, degrees: -5))
        XCTAssertEqual(commands.wristTargets.last!.degrees, -20, accuracy: 0.01)
    }

    func testA6AWristNeedsTracking() {
        var rig = Rig(.screenTurns)
        rig.facts.trackingRefusal = .notTracking
        rig.touchDown(1, at: Rig.middle)
        rig.wait(0.1)
        XCTAssertEqual(rig.rotate(turn: 8), [.cue(.refused(.notTracking))])
        XCTAssertEqual(rig.phase(.touch(1)), .dead)
        XCTAssertEqual(rig.lift(1), [])
    }

    func testA6ATurnInsideThePalmWindowCommitsWhenItEnds() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.middle)
        XCTAssertEqual(rig.rotate(turn: 7, steps: 3, dt: 0.01), [])
        let commands = rig.wait(0.07)
        XCTAssertEqual(commands.withoutUpdates, [.startWrist])
        XCTAssertEqual(commands.wristTargets.count, 1)
        XCTAssertEqual(commands.wristTargets.first?.degrees ?? 0, 7, accuracy: 1e-9)

        // A turn that went back under 5° before the window ended does not commit.
        rig.lift(1, after: 0.1)
        rig.orient(turn: 0)
        rig.touchDown(2, at: Rig.middle, after: 0.1)
        rig.rotate(turn: 6, steps: 2, dt: 0.01)
        rig.rotate(turn: 2, steps: 2, dt: 0.01)
        XCTAssertEqual(rig.wait(0.1), [])
        XCTAssertEqual(rig.phase(.touch(2)), .waiting)
    }

    func testA6tAttitudeIsJudgedBeforeAMoveAtTheSameInstant() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.middle)
        rig.wait(0.1)
        rig.slide(1, mm: 9, degrees: 90)
        rig.turn = 6
        // The move alone would open; the attitude alone would commit the wrist.
        let up = Rig.middle + SIMD2(0, -10 * Rig.pointsPerMm)
        let commands = rig.batch([rig.sample(1, .moved, up, radius: 8), .attitude(rig.attitude)], after: 0.01)
        XCTAssertEqual(commands.withoutUpdates, [.startWrist])
        XCTAssertEqual(rig.phase(.touch(1)), .engaged(.wrist))
    }

    func testA7AnOpenTouchEndedStopsTheGripper() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.middle)
        rig.wait(0.1)
        rig.slide(1, mm: 10, degrees: 90)
        XCTAssertEqual(rig.lift(1, after: 0.5), [.stopGripper])
    }

    func testA7wAWristTouchEndedStopsTheWrist() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.middle)
        rig.wait(0.1)
        rig.rotate(turn: 12)
        XCTAssertEqual(rig.lift(1, after: 0.5), [.stopWrist])
        XCTAssertEqual(rig.rotate(turn: 30), [], "no updates after the stop")
    }

    func testA7uAnUndecidedOrDeadTouchEndedDoesNothing() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.middle)
        XCTAssertEqual(rig.lift(1, after: 0.5), [])
        rig.touchDown(2, at: Rig.middle, after: 0.1)
        rig.wait(0.1)
        rig.slide(2, mm: 10, degrees: 0)
        XCTAssertEqual(rig.lift(2), [])
    }

    func testA8AKeyDisplacesAnUndecidedTouchSilently() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.middle)
        rig.wait(0.2)
        XCTAssertEqual(rig.press(.upper), [.startTranslation])
        XCTAssertEqual(rig.phase(.touch(1)), .dead)
        // It stays dead, silently, after the key is let go too.
        XCTAssertEqual(rig.release(.upper, after: 0.3), [.stopTranslation])
        XCTAssertEqual(rig.slide(1, mm: 12, degrees: 90), [])
        XCTAssertEqual(rig.rotate(turn: 10), [])
        XCTAssertEqual(rig.lift(1), [])

        var lower = Rig(.screenTurns)
        lower.touchDown(1, at: Rig.middle)
        XCTAssertEqual(lower.press(.lower, after: 0.05), [.startGripper(.closed)])
        XCTAssertEqual(lower.phase(.touch(1)), .dead)
    }

    func testA9AKeyWhileATouchOwnsTheArmIsDead() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.middle)
        rig.wait(0.1)
        rig.slide(1, mm: 10, degrees: 90)
        XCTAssertEqual(rig.press(.upper), [.cue(.dead)])
        XCTAssertEqual(rig.press(.lower), [.cue(.dead)])
        XCTAssertEqual(rig.release(.upper), [])
        XCTAssertEqual(rig.lift(1), [.stopGripper])
        XCTAssertEqual(rig.release(.lower), [])

        rig.touchDown(2, at: Rig.middle, after: 1)
        rig.wait(0.1)
        rig.rotate(turn: 9)
        XCTAssertEqual(rig.press(.lower), [.cue(.dead)])
        XCTAssertEqual(rig.lift(2), [.stopWrist])
    }

    func testA10PhoneRotationDuringAnOpenTouchIsIgnored() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.middle)
        rig.wait(0.1)
        rig.slide(1, mm: 10, degrees: 90)
        XCTAssertEqual(rig.rotate(turn: 30, tilt: 10), [])
        XCTAssertEqual(rig.lift(1), [.stopGripper])
    }

    func testA11AnUndecidedTouchNeverTimesOut() {
        var rig = Rig(.screenTurns)
        rig.touchDown(1, at: Rig.middle)
        for _ in 0..<300 { XCTAssertEqual(rig.wait(1.0 / 30), []) }
        XCTAssertEqual(rig.phase(.touch(1)), .waiting)
        XCTAssertNil(rig.arbiter.nextDeadline)
    }

    func testEveryUpwardSlideAngleHasExactlyOneOutcome() {
        // Continuous 1 mm moves at every angle in 0.1° steps: up-dominant opens, anything else is dead with NO.
        for tenth in 0..<3600 where tenth % 900 != 450 {
            // The exact diagonals depend on rounding in the sweep's own trigonometry; testA5AnExactDiagonalIsNotUp
            // covers them with exact points.
            let degrees = Double(tenth) / 10
            var rig = Rig(.screenTurns)
            rig.touchDown(1, at: Rig.middle)
            rig.wait(0.1)
            let commands = rig.slide(1, mm: 25, degrees: degrees)
            let up = sin(degrees * .pi / 180) > abs(cos(degrees * .pi / 180)) + 1e-12
            XCTAssertEqual(commands, up ? [.startGripper(.open)] : [.cue(.dead)], "\(degrees)°")
        }
    }

    func testEveryTurnAndTiltBelowTenDegreesHasAtMostOneOutcome() {
        for turn in stride(from: 0.0, through: 10, by: 0.5) {
            for tilt in stride(from: 0.0, through: 10, by: 0.5) {
                // A straight sweep keeps the ratio of the two; exactly 0.6 is the boundary itself.
                if turn > 0, tilt > 0, abs(min(turn, tilt) / max(turn, tilt) - 0.6) < 1e-9 { continue }
                var rig = Rig(.screenTurns)
                rig.touchDown(1, at: Rig.middle)
                rig.wait(0.1)
                let commands = rig.rotate(turn: turn, tilt: tilt, steps: 20).withoutUpdates
                let dominant = (turn >= 5 && tilt < 0.6 * turn) || (tilt >= 5 && turn < 0.6 * tilt)
                // Rotation alone commits or does nothing; it never cues NO.
                XCTAssertEqual(commands, dominant ? [.startWrist] : [], "turn \(turn) tilt \(tilt)")
            }
        }
    }
}
