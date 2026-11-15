import simd
import XCTest
@testable import TeleopCore

/// Lock, variant 1: the accepted press of the upper key starts a follow nobody holds, its release does nothing, and
/// the next press ends it. Everything else about the keys is as in 1.0.1.
final class LockPressPressTests: XCTestCase {
    typealias Rig = ArbiterRig

    func testThePressLatchesItsReleaseDoesNothingTheNextPressStops() {
        var rig = Rig(.screenTurns, assist: Rig.lockPressPress())
        XCTAssertEqual(rig.press(.upper, after: 0.1), [.startTranslation, .cue(.drive(.latched))])
        XCTAssertEqual(rig.arbiter.engagement, .latched(since: rig.time))
        XCTAssertEqual(rig.arbiter.engagedHold, .translation, "the session runs one translation hold for it")
        XCTAssertEqual(rig.phase(.key(.upper)), .dead)
        XCTAssertEqual(rig.release(.upper, after: 0.3), [])
        XCTAssertEqual(rig.wait(1), [])
        XCTAssertTrue(rig.isLatched, "still following with nothing down")
        XCTAssertTrue(rig.arbiter.held.isEmpty)
        XCTAssertEqual(rig.press(.upper, after: 0.5), [.stopTranslation, .cue(.drive(.stoppedByYou))])
        XCTAssertNil(rig.arbiter.engagement)
        XCTAssertEqual(rig.phase(.key(.upper)), .dead, "the key that ended it is dead until released")
        XCTAssertEqual(rig.wait(1), [])
        XCTAssertEqual(rig.release(.upper, after: 0.2), [])
        XCTAssertNil(rig.phase(.key(.upper)))
        XCTAssertEqual(rig.press(.upper, after: 0.5), [.startTranslation, .cue(.drive(.latched))], "and latches again")
    }

    /// A press the facts refuse is refused exactly as a held start is in 1.0.1: NO and the reason, the key dead.
    func testARefusedPressIsTheOneZeroOneRefusal() {
        let cases: [(String, InputFacts, InputRefusal)] = [
            ("posture", InputFacts(translationRefusal: .posture), .posture),
            ("tracking", InputFacts(trackingRefusal: .notTracking), .notTracking),
            ("no link", InputFacts(refusal: .noLink), .noLink),
            ("stopped", InputFacts(refusal: .stopped), .stopped),
            ("settings", InputFacts(refusal: .settingsOpen), .settingsOpen),
            ("slow link", InputFacts(refusal: .slowLink), .slowLink),
            ("wait", InputFacts(refusal: .wait), .wait),
        ]
        for (name, facts, refusal) in cases {
            var off = Rig(.screenTurns)
            var on = Rig(.screenTurns, assist: Rig.lockPressPress())
            off.facts = facts
            on.facts = facts
            let expected = off.press(.upper, after: 0.1)
            XCTAssertEqual(expected, [.cue(.refused(refusal))], name)
            XCTAssertEqual(on.press(.upper, after: 0.1), expected, name)
            XCTAssertNil(on.arbiter.engagement, name)
            XCTAssertEqual(on.phase(.key(.upper)), .dead, name)
            XCTAssertEqual(on.arbiter.startsThisCall, [], name)
            XCTAssertEqual(on.release(.upper, after: 0.2), [], name)
        }
    }

    /// The key checks of 1.0.1 come first: a stale key, the other key down, a chord and a replayed key are dead.
    func testTheKeyChecksOfOneZeroOneComeFirst() {
        let scripts: [(String, (inout Rig) -> Void)] = [
            ("the other key down", { $0.press(.lower, after: 0.1) }),
            (
                "a chord",
                {
                    $0.press(.lower, after: 0.1)
                    $0.release(.lower, after: 0.01)
                }
            ),
            (
                "a replay",
                {
                    $0.press(.lower, after: 0.1)
                    $0.release(.lower, after: 0.3)
                }
            ),
            (
                "a stale key",
                {
                    $0.press(.upper, after: 0.1)
                    $0.send(.endAllHolds)
                    $0.send(.becameActive, after: 0.5)
                }
            ),
        ]
        for (name, script) in scripts {
            var off = Rig(.screenTurns)
            var on = Rig(.screenTurns, assist: Rig.lockPressPress())
            script(&off)
            script(&on)
            let dt = name == "a chord" ? 0.02 : name == "a replay" ? 0.1 : 0.5
            let expected = off.press(.upper, after: dt)
            XCTAssertEqual(expected, [.cue(.dead)], name)
            XCTAssertEqual(on.press(.upper, after: dt), expected, name)
            XCTAssertFalse(on.isLatched, name)
            XCTAssertEqual(on.phase(.key(.upper)), .dead, name)
        }
    }

    /// The lower key holds as in 1.0.1, in both schemes: the jaws in scheme A, the wrist in scheme B.
    func testTheLowerKeyStillHoldsToMove() {
        for scheme in [InputScheme.screenTurns, .keyTurns] {
            let (off, on) = Self.both(scheme) {
                $0.press(.lower, after: 0.1)
                $0.rotate(turn: 15)
                $0.release(.lower, after: 0.3)
            }
            XCTAssertEqual(on.log, off.log, "\(scheme)")
            XCTAssertTrue(off.log.contains(.stopGripper) || off.log.contains(.stopWrist), "\(scheme)")
            XCTAssertNil(on.arbiter.engagement, "\(scheme)")
        }
    }

    /// A wrist hold on a thumb and a jaw hold on a half end with their input, as in 1.0.1.
    func testWristAndJawHoldsNeverLatch() {
        let scripts: [(InputScheme, String, (inout Rig) -> Void)] = [
            (
                .screenTurns, "a thumb turning the wrist",
                {
                    $0.touchDown(1, at: Rig.middle, after: 0.1)
                    $0.wait(0.15)
                    $0.rotate(turn: 15)
                    $0.lift(1, after: 0.3)
                }
            ),
            (
                .screenTurns, "a thumb opening the jaws",
                {
                    $0.touchDown(1, at: Rig.middle, after: 0.1)
                    $0.slide(1, mm: 12, degrees: 90)
                    $0.lift(1, after: 0.3)
                }
            ),
            (
                .keyTurns, "a thumb holding a half",
                {
                    $0.touchDown(1, at: Rig.rightHalf, after: 0.1)
                    $0.wait(0.2)
                    $0.lift(1, after: 0.3)
                }
            ),
        ]
        for (scheme, name, script) in scripts {
            let (off, on) = Self.both(scheme, script)
            XCTAssertEqual(on.log, off.log, name)
            XCTAssertTrue(off.log.contains(.stopGripper) || off.log.contains(.stopWrist), name)
            XCTAssertNil(on.arbiter.engagement, name)
        }
    }

    /// The same script on a 1.0.1 rig and on one with variant 1.
    private static func both(_ scheme: InputScheme, _ script: (inout Rig) -> Void) -> (off: Rig, on: Rig) {
        var off = Rig(scheme)
        var on = Rig(scheme, assist: Rig.lockPressPress())
        script(&off)
        script(&on)
        return (off, on)
    }

    /// Posture is judged from the press on: a phone tipped 0.1 s later ends the follow.
    func testThePostureGateCoversTheFollowFromThePress() {
        var rig = Rig(.screenTurns, assist: Rig.lockPressPress())
        rig.press(.upper, after: 0.1)
        rig.facts.translationRefusal = .posture
        XCTAssertEqual(rig.wait(0.1), [.stopTranslation, .cue(.drive(.ended(.posture)))])
        XCTAssertNil(rig.arbiter.engagement)
        XCTAssertEqual(rig.release(.upper, after: 0.1), [])
    }

    /// The facts of a call are from before a STOP in it, so a press after the STOP in the same call is refused as the
    /// robot being stopped.
    func testThePressAfterStopInTheSameCallIsRefused() {
        var rig = Rig(.screenTurns, assist: Rig.lockPressPress())
        let stop = rig.sample(1, .began, Rig.bottomBand, radius: 8)
        XCTAssertEqual(rig.batch([stop, .keyDown(.upper)], after: 0.1), [.emergencyStop, .cue(.refused(.stopped))])
        XCTAssertNil(rig.arbiter.engagement)
        XCTAssertEqual(rig.phase(.key(.upper)), .dead)
        XCTAssertEqual(rig.arbiter.startsThisCall, [])
        XCTAssertEqual(rig.release(.upper, after: 0.2), [])
        XCTAssertEqual(rig.lift(1), [])
        XCTAssertEqual(rig.press(.upper, after: 0.5), [.startTranslation, .cue(.drive(.latched))], "a later call may")
    }

    /// A press is before a STOP in the same call in time: it latches, and the STOP ends what it started, with the
    /// stop going out first and no ending cue of the follow's own.
    func testAPressBeforeStopInTheSameCallLatchesAndTheStopEndsIt() {
        var rig = Rig(.screenTurns, assist: Rig.lockPressPress())
        let stop = rig.sample(1, .began, Rig.bottomBand, radius: 8)
        XCTAssertEqual(
            rig.batch([.keyDown(.upper), stop], after: 0.1),
            [.startTranslation, .cue(.drive(.latched)), .emergencyStop, .stopTranslation])
        XCTAssertNil(rig.arbiter.engagement)
        XCTAssertEqual(rig.release(.upper, after: 0.2), [])

        var unlinked = Rig(.screenTurns, assist: Rig.lockPressPress())
        unlinked.facts.connectionUp = false
        XCTAssertEqual(
            unlinked.batch([.keyDown(.upper), stop], after: 0.1),
            [.startTranslation, .cue(.drive(.latched)), .emergencyStop, .stopTranslation, .cue(.refused(.notStopped))])
    }

    /// Each start of the last call is recorded with what the link must follow, until the next call.
    func testEachStartOfTheCallIsRecorded() {
        var rig = Rig(.screenTurns, assist: Rig.lockPressPress())
        let stop = rig.sample(1, .began, Rig.bottomBand, radius: 8)
        rig.batch([.keyDown(.upper), stop], after: 0.1)
        XCTAssertEqual(rig.arbiter.startsThisCall, [.phone], "the start the STOP ended is still recorded")
        rig.wait(0.1)
        XCTAssertEqual(rig.arbiter.startsThisCall, [])
        rig.release(.upper)
        rig.lift(1)
        rig.press(.upper, after: 0.5)
        XCTAssertEqual(rig.arbiter.startsThisCall, [.phone], "a latched start")

        var off = Rig(.screenTurns)
        off.press(.upper, after: 0.1)
        XCTAssertEqual(off.arbiter.startsThisCall, [.phone], "a held start of 1.0.1")
        off.release(.upper, after: 0.3)
        XCTAssertEqual(off.arbiter.startsThisCall, [])
        off.press(.lower, after: 0.5)
        XCTAssertEqual(off.arbiter.startsThisCall, [], "only translation starts are recorded")
    }

    /// S10: the latching key's release does nothing, and the follow's limit is the next thing to tick for.
    func testTheLatchingKeysReleaseDoesNothing() {
        var rig = Rig(.keyTurns, assist: Rig.lockPressPress(limit: 5))
        rig.press(.upper, after: 0.1)
        let since = rig.time
        XCTAssertEqual(rig.arbiter.nextDeadline, since + 5)
        XCTAssertEqual(rig.release(.upper, after: 2), [])
        XCTAssertEqual(rig.arbiter.engagement, .latched(since: since))
        XCTAssertNil(rig.phase(.key(.upper)))
        XCTAssertEqual(rig.arbiter.nextDeadline, since + 5)
    }
}
