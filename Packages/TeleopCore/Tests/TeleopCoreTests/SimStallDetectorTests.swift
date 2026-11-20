import Foundation
import XCTest
@testable import TeleopCore

/// The one fact "the simulator is not responding": each way it is set, the one way it clears, and that a running
/// simulator never sets it.
final class SimStallDetectorTests: XCTestCase {
    /// One input at a time, on a clock in milliseconds.
    private struct Script {
        var detector = SimStallDetector()
        var now = 0
        /// Server clock, nanoseconds.
        var serverNs: UInt64 = 1_000_000_000_000

        /// A state the loop wrote `ageMs` before it was sent, `gapMs` after the last one.
        mutating func state(
            capturedAdvanceMs: Int, ageMs: Int, gapMs: Int = 200, simStalled: Bool? = nil, captured: UInt64? = nil
        ) -> SimStallDetector {
            now += gapMs
            serverNs += UInt64(capturedAdvanceMs) * 1_000_000
            let capturedNs = captured ?? serverNs
            let health = StateHealth(
                capturedNs: capturedNs, sentNs: capturedNs + UInt64(ageMs) * 1_000_000, simStalled: simStalled)
            detector.observe(.state(health), at: now)
            return detector
        }

        /// A state from a running loop: written just now, after the one before.
        mutating func fresh(gapMs: Int = 200, simStalled: Bool? = nil) -> SimStallDetector {
            state(capturedAdvanceMs: gapMs, ageMs: 5, gapMs: gapMs, simStalled: simStalled)
        }

        mutating func at(_ ms: Int, _ input: SimStallDetector.Input) -> SimStallDetector {
            now = ms
            detector.observe(input, at: now)
            return detector
        }
    }

    /// A stream of states whose captured time no longer moves: each older when sent than the one before.
    private func frozenStream(_ script: inout Script, count: Int, startAgeMs: Int = 2100) {
        let captured = script.serverNs
        for index in 0..<count {
            _ = script.state(capturedAdvanceMs: 0, ageMs: startAgeMs + 200 * index, captured: captured)
        }
    }

    // MARK: Each trigger

    func testTheServerFlagSetsIt() {
        var script = Script()
        _ = script.fresh()
        let after = script.fresh(simStalled: true)
        XCTAssertTrue(after.stalled)
        XCTAssertEqual(after.trigger, .serverFlag)
    }

    func testTheServerFlagCountsWithoutTiming() {
        var detector = SimStallDetector()
        detector.observe(.state(StateHealth(simStalled: true)), at: 0)
        XCTAssertTrue(detector.stalled, "a server that says so is believed, timing or not")
    }

    func testARefusalSaysSoForAnyRequest() {
        for request in ["pose_start", "estop_reset", "reset_scene", "gripper_jog_start", "orient_start"] {
            var detector = SimStallDetector()
            XCTAssertTrue(detector.observe(.refused(request: request, reason: "sim_stalled"), at: 0), request)
            XCTAssertEqual(detector.trigger, .serverRefusal, request)
        }
    }

    func testCapturedTimeThatStopsSetsItOnTheThirdStaleState() {
        var script = Script()
        _ = script.fresh()
        frozenStream(&script, count: 2)
        XCTAssertFalse(script.detector.stalled, "two stale states are not yet a stream")
        frozenStream(&script, count: 1, startAgeMs: 2600)
        XCTAssertTrue(script.detector.stalled)
        XCTAssertEqual(script.detector.trigger, .frozenTime)
    }

    func testStaleStatesWhoseAgeDoesNotGrowAreNotAFrozenLoop() {
        var script = Script()
        _ = script.fresh()
        // Old when sent but each written later than the last: a slow server, not a stopped loop.
        for _ in 0..<6 { _ = script.state(capturedAdvanceMs: 200, ageMs: 2500) }
        XCTAssertFalse(script.detector.stalled)
    }

    func testAYoungStateBreaksTheStaleRun() {
        var script = Script()
        _ = script.fresh()
        frozenStream(&script, count: 2)
        _ = script.fresh()
        frozenStream(&script, count: 2, startAgeMs: 2100)
        XCTAssertFalse(script.detector.stalled)
    }

    func testBusyForMoreThanThreeSecondsSetsIt() {
        var script = Script()
        _ = script.fresh()
        XCTAssertFalse(script.at(1000, .refused(request: "pose_start", reason: "busy")).stalled)
        XCTAssertFalse(script.at(3000, .refused(request: "pose_start", reason: "busy")).stalled)
        XCTAssertFalse(script.at(4000, .refused(request: "pose_start", reason: "busy")).stalled, "exactly 3 s")
        let after = script.at(4001, .refused(request: "pose_start", reason: "busy"))
        XCTAssertTrue(after.stalled)
        XCTAssertEqual(after.trigger, .busy)
    }

    func testBusyIsAlsoJudgedByTime() {
        var script = Script()
        _ = script.fresh()
        _ = script.at(1000, .refused(request: "pose_start", reason: "busy"))
        XCTAssertFalse(script.at(3900, .tick).stalled)
        XCTAssertTrue(script.at(4100, .tick).stalled)
    }

    func testAStopAnswerEndsTheBusyRun() {
        var script = Script()
        _ = script.fresh()
        _ = script.at(1000, .stopSent(start: 7))
        _ = script.at(1100, .refused(request: "pose_start", reason: "busy"))
        _ = script.at(1500, .stopAnswered(start: 7))
        XCTAssertFalse(script.at(4200, .refused(request: "pose_start", reason: "busy")).stalled)
        XCTAssertFalse(script.at(7000, .tick).stalled, "the run began again at 4.2 s")
        XCTAssertTrue(script.at(7300, .tick).stalled)
    }

    func testAStopUnansweredForThreeSecondsSetsIt() {
        var script = Script()
        _ = script.fresh()
        _ = script.at(1000, .stopSent(start: 91))
        XCTAssertFalse(script.at(3999, .tick).stalled)
        let after = script.at(4000, .tick)
        XCTAssertTrue(after.stalled)
        XCTAssertEqual(after.trigger, .stopUnanswered)
    }

    func testAnAnsweredStopNeverSetsIt() {
        var script = Script()
        _ = script.fresh()
        _ = script.at(1000, .stopSent(start: 91))
        _ = script.at(1200, .stopAnswered(start: 91))
        XCTAssertFalse(script.at(10_000, .tick).stalled)
    }

    func testARefusedReleaseWithAnotherSignSetsIt() {
        // The newest state is stale, short of a frozen stream.
        var stale = Script()
        _ = stale.fresh()
        frozenStream(&stale, count: 1)
        XCTAssertTrue(stale.at(stale.now + 10, .refused(request: "estop_reset", reason: "estop_not_frozen")).stalled)
        XCTAssertEqual(stale.detector.trigger, .releaseRefused)
        // A move was refused busy since the last stop answer.
        var busy = Script()
        _ = busy.fresh()
        _ = busy.at(500, .refused(request: "pose_start", reason: "busy"))
        XCTAssertTrue(busy.at(900, .refused(request: "estop_reset", reason: "estop_not_frozen")).stalled)
        // A stop has waited longer than the link waits for an answer.
        var stop = Script()
        _ = stop.fresh()
        _ = stop.at(500, .stopSent(start: 3))
        XCTAssertTrue(
            stop.at(500 + TeleopLink.finishWaitMs + 1, .refused(request: "estop_reset", reason: "estop_not_frozen"))
                .stalled)
    }

    func testARefusedReleaseAloneIsTheLoopNotYetHoldingTheArm() {
        var script = Script()
        _ = script.fresh()
        _ = script.at(300, .stopSent(start: 3))
        // Released within a pass of the stop: the loop has not frozen the arm yet. Nothing else is wrong.
        XCTAssertFalse(script.at(320, .refused(request: "estop_reset", reason: "estop_not_frozen")).stalled)
        XCTAssertFalse(script.at(330, .refused(request: "pose_start", reason: "estop_not_frozen")).stalled)
    }

    // MARK: Clearing

    func testOnlyFreshAdvancingStatesClearIt() {
        var script = Script()
        _ = script.fresh()
        frozenStream(&script, count: 3)
        XCTAssertTrue(script.detector.stalled)
        // Time passing, answers and refusals other than these do not clear it.
        _ = script.at(script.now + 10_000, .tick)
        _ = script.at(script.now + 10, .stopAnswered(start: 1))
        _ = script.at(script.now + 10, .refused(request: "pose_start", reason: "estop_active"))
        XCTAssertTrue(script.detector.stalled)
        // The same young state again does not count: its captured time did not move.
        let captured = script.serverNs
        _ = script.state(capturedAdvanceMs: 0, ageMs: 5, captured: captured)
        XCTAssertTrue(script.detector.stalled)
        XCTAssertTrue(script.fresh().stalled)
        XCTAssertTrue(script.fresh().stalled)
        let cleared = script.fresh()
        XCTAssertFalse(cleared.stalled, "three fresh states in a row")
        XCTAssertNil(cleared.trigger)
    }

    func testAFreshStateStillFlaggedDoesNotCount() {
        var script = Script()
        _ = script.fresh(simStalled: true)
        for _ in 0..<5 { _ = script.fresh(simStalled: true) }
        XCTAssertTrue(script.detector.stalled)
        _ = script.fresh(simStalled: false)
        _ = script.fresh(simStalled: false)
        XCTAssertFalse(script.fresh(simStalled: false).stalled)
    }

    func testAStaleStateBreaksTheFreshRun() {
        var script = Script()
        _ = script.fresh()
        frozenStream(&script, count: 3)
        _ = script.fresh()
        _ = script.fresh()
        frozenStream(&script, count: 1)
        _ = script.fresh()
        _ = script.fresh()
        XCTAssertTrue(script.detector.stalled, "the run began again after the stale state")
        XCTAssertFalse(script.fresh().stalled)
    }

    func testAFreshStateDropsTheSignsGatheredSoFar() {
        var script = Script()
        _ = script.fresh()
        _ = script.at(script.now + 10, .stopSent(start: 4))
        _ = script.at(script.now + 10, .refused(request: "pose_start", reason: "busy"))
        // The loop runs: another client's hold is busy, and the answer is only late.
        _ = script.fresh()
        XCTAssertFalse(script.at(script.now + 10_000, .tick).stalled)
    }

    // MARK: A running simulator

    func testAnIdleArmWithAdvancingCapturedTimeNeverSetsIt() {
        var script = Script()
        for _ in 0..<3000 {
            _ = script.state(capturedAdvanceMs: 200, ageMs: Int.random(in: 0...40))
            XCTAssertFalse(script.detector.stalled)
            _ = script.at(script.now, .tick)
        }
        XCTAssertFalse(script.detector.stalled)
        XCTAssertNil(script.detector.trigger)
    }

    func testStatesFromBothConnectionsTogetherNeverSetIt() {
        var script = Script()
        for _ in 0..<500 {
            // The same state on both connections, then an older one the other connection overtook.
            let captured = script.serverNs + 200_000_000
            _ = script.state(capturedAdvanceMs: 200, ageMs: 3, gapMs: 100)
            _ = script.state(capturedAdvanceMs: 0, ageMs: 9, gapMs: 1, captured: captured)
            _ = script.state(capturedAdvanceMs: 0, ageMs: 9, gapMs: 1, captured: captured - 16_000_000)
        }
        XCTAssertFalse(script.detector.stalled)
    }

    func testWithoutTimingOnlyTheServerCanSayIt() {
        var detector = SimStallDetector()
        detector.observe(.state(StateHealth()), at: 0)
        detector.observe(.refused(request: "pose_start", reason: "busy"), at: 0)
        detector.observe(.stopSent(start: 1), at: 0)
        detector.observe(.refused(request: "estop_reset", reason: "estop_not_frozen"), at: 1000)
        detector.observe(.tick, at: 60_000)
        XCTAssertFalse(detector.stalled, "nothing could ever clear it, so the app does not judge by time")
        detector.observe(.refused(request: "pose_start", reason: "sim_stalled"), at: 60_001)
        XCTAssertTrue(detector.stalled)
    }

    // MARK: Two levels

    func testAPauseOfFiveSecondsThatRecoversNeverReachesNotResponding() {
        var script = Script()
        _ = script.fresh()
        // 5 s of states whose captured time stands still, then the loop runs again.
        frozenStream(&script, count: 25)
        XCTAssertEqual(script.detector.level, .paused)
        XCTAssertEqual(script.detector.trigger, .frozenTime)
        _ = script.fresh()
        _ = script.fresh()
        XCTAssertEqual(script.fresh().level, .running)
        XCTAssertNil(script.detector.trigger)
    }

    func testAPauseOfFifteenSecondsIsNotResponding() {
        var script = Script()
        _ = script.fresh()
        frozenStream(&script, count: 3)
        let pausedAt = script.now
        XCTAssertEqual(script.detector.level, .paused)
        XCTAssertEqual(script.at(pausedAt + SimStallDetector.notRespondingMs - 1, .tick).level, .paused)
        XCTAssertEqual(script.at(pausedAt + SimStallDetector.notRespondingMs, .tick).level, .notResponding)
        XCTAssertEqual(script.detector.trigger, .frozenTime, "the trigger that paused it is kept")
        _ = script.fresh()
        _ = script.fresh()
        XCTAssertEqual(script.fresh().level, .running, "fresh states clear this level too")
    }

    func testThePausesMeasuredOnTheSimulatorAllStayPaused() {
        XCTAssertEqual(SimStallDetector.notRespondingMs, 15_000, "pauses of 4.5 to 8.7 s were measured, all recovered")
        var script = Script()
        _ = script.fresh()
        frozenStream(&script, count: 3)
        XCTAssertEqual(script.at(script.now + 8700, .tick).level, .paused)
    }

    func testTheServerFlagWithAnOldLoopIsNotRespondingAtOnce() {
        var detector = SimStallDetector()
        detector.observe(.state(StateHealth(simStalled: true, loopAgeMs: 14_999)), at: 0)
        XCTAssertEqual(detector.level, .paused)
        var old = SimStallDetector()
        old.observe(.state(StateHealth(simStalled: true, loopAgeMs: 15_000)), at: 0)
        XCTAssertEqual(old.level, .notResponding)
    }

    func testNothingIsEnteredWhileTheSceneResets() {
        var script = Script()
        _ = script.fresh()
        // The 5.1 s reset measured on the simulator: captured time stands still while the state says resetting.
        let captured = script.serverNs
        for index in 0..<30 {
            script.now += 200
            let health = StateHealth(
                capturedNs: captured, sentNs: captured + UInt64(200 + 200 * index) * 1_000_000, resetting: true)
            XCTAssertFalse(script.detector.observe(.state(health), at: script.now), "\(index)")
        }
        _ = script.at(script.now + 10, .refused(request: "pose_start", reason: "sim_stalled"))
        XCTAssertEqual(script.detector.level, .running)
        // A reset that never ends is still found, once its allowance has passed.
        script.now += SimStallDetector.resetAllowanceMs
        for index in 0..<3 {
            script.now += 200
            let health = StateHealth(
                capturedNs: captured, sentNs: captured + UInt64(20_000 + 200 * index) * 1_000_000, resetting: true)
            script.detector.observe(.state(health), at: script.now)
        }
        XCTAssertEqual(script.detector.level, .paused)
    }

    func testNothingIsEnteredForTwelveSecondsAfterAResetThisPhoneAskedFor() {
        var script = Script()
        _ = script.fresh()
        _ = script.at(script.now, .resetRequested)
        let asked = script.now
        frozenStream(&script, count: 20)
        _ = script.at(asked + 11_000, .refused(request: "reset_scene", reason: "busy"))
        XCTAssertEqual(script.at(asked + 11_999, .tick).level, .running)
        _ = script.at(asked + 12_000, .refused(request: "pose_start", reason: "sim_stalled"))
        XCTAssertEqual(script.detector.level, .paused, "after the allowance a sign counts")
    }

    // MARK: Every way in has a way out

    /// One way into paused or not responding, and the states that must clear it: the same kind of information that
    /// got it in, so no server can leave the operator held back for good.
    private struct WayIn {
        let name: String
        let level: SimStallDetector.Level
        let trigger: SimStallDetector.Trigger
        /// Puts the detector into `level`.
        let enter: (inout Script) -> Void
        /// One state of the kind that clears it, `freshStates` of them in a row.
        let healthy: (inout Script) -> Void
    }

    /// A state with no timing, as a server without the loop's timestamps sends it.
    private static func untimed(_ script: inout Script, _ health: StateHealth) {
        script.now += 200
        script.detector.observe(.state(health), at: script.now)
    }

    private static let flaggedHealthy = StateHealth(simStalled: false, loopAgeMs: 4)

    private var waysIn: [WayIn] {
        let fresh: (inout Script) -> Void = { _ = $0.fresh() }
        let flagged: (inout Script) -> Void = { Self.untimed(&$0, Self.flaggedHealthy) }
        return [
            WayIn(
                name: "server flag, no timing", level: .paused, trigger: .serverFlag,
                enter: { Self.untimed(&$0, StateHealth(simStalled: true, loopAgeMs: 4600)) }, healthy: flagged),
            WayIn(
                name: "server flag with an old loop, no timing", level: .notResponding, trigger: .serverFlag,
                enter: { Self.untimed(&$0, StateHealth(simStalled: true, loopAgeMs: 16_000)) }, healthy: flagged),
            WayIn(
                name: "server flag with timing", level: .paused, trigger: .serverFlag,
                enter: {
                    _ = $0.fresh()
                    _ = $0.fresh(simStalled: true)
                }, healthy: fresh),
            WayIn(
                name: "refusal, server sends no health at all", level: .paused, trigger: .serverRefusal,
                enter: {
                    Self.untimed(&$0, StateHealth())
                    _ = $0.at($0.now + 10, .refused(request: "pose_start", reason: "sim_stalled"))
                }, healthy: { Self.untimed(&$0, StateHealth()) }),
            WayIn(
                name: "refusal, server sends the flag without timing", level: .paused, trigger: .serverRefusal,
                enter: {
                    Self.untimed(&$0, Self.flaggedHealthy)
                    _ = $0.at($0.now + 10, .refused(request: "estop_reset", reason: "sim_stalled"))
                }, healthy: flagged),
            WayIn(
                name: "refusal with timing", level: .paused, trigger: .serverRefusal,
                enter: {
                    _ = $0.fresh()
                    _ = $0.at($0.now + 10, .refused(request: "pose_start", reason: "sim_stalled"))
                }, healthy: fresh),
            WayIn(
                name: "frozen time", level: .paused, trigger: .frozenTime,
                enter: {
                    _ = $0.fresh()
                    let captured = $0.serverNs
                    for index in 0..<3 {
                        _ = $0.state(capturedAdvanceMs: 0, ageMs: 2100 + 200 * index, captured: captured)
                    }
                }, healthy: fresh),
            WayIn(
                name: "busy", level: .paused, trigger: .busy,
                enter: {
                    _ = $0.fresh()
                    _ = $0.at($0.now + 10, .refused(request: "pose_start", reason: "busy"))
                    _ = $0.at($0.now + SimStallDetector.busyMs + 1, .tick)
                }, healthy: fresh),
            WayIn(
                name: "stop unanswered", level: .paused, trigger: .stopUnanswered,
                enter: {
                    _ = $0.fresh()
                    _ = $0.at($0.now + 10, .stopSent(start: 5))
                    _ = $0.at($0.now + SimStallDetector.stopAnswerMs, .tick)
                }, healthy: fresh),
            WayIn(
                name: "release refused", level: .paused, trigger: .releaseRefused,
                enter: {
                    _ = $0.fresh()
                    _ = $0.at($0.now + 10, .refused(request: "pose_start", reason: "busy"))
                    _ = $0.at($0.now + 10, .refused(request: "estop_reset", reason: "estop_not_frozen"))
                }, healthy: fresh),
            WayIn(
                name: "paused too long, with timing", level: .notResponding, trigger: .frozenTime,
                enter: {
                    _ = $0.fresh()
                    let captured = $0.serverNs
                    for index in 0..<3 {
                        _ = $0.state(capturedAdvanceMs: 0, ageMs: 2100 + 200 * index, captured: captured)
                    }
                    _ = $0.at($0.now + SimStallDetector.notRespondingMs, .tick)
                }, healthy: fresh),
            WayIn(
                name: "paused too long, flag without timing", level: .notResponding, trigger: .serverFlag,
                enter: {
                    Self.untimed(&$0, StateHealth(simStalled: true, loopAgeMs: 100))
                    _ = $0.at($0.now + SimStallDetector.notRespondingMs, .tick)
                }, healthy: flagged),
        ]
    }

    func testEveryWayInHasAWayOutWithTheSameInformation() {
        for way in waysIn {
            var script = Script()
            way.enter(&script)
            XCTAssertEqual(script.detector.level, way.level, way.name)
            XCTAssertEqual(script.detector.trigger, way.trigger, way.name)
            for index in 1..<SimStallDetector.freshStates {
                way.healthy(&script)
                XCTAssertTrue(script.detector.stalled, "\(way.name): \(index) healthy states are not yet enough")
            }
            way.healthy(&script)
            XCTAssertEqual(script.detector.level, .running, "\(way.name): cleared")
            XCTAssertNil(script.detector.trigger, way.name)
        }
    }

    func testAFlagWithAnOldLoopDoesNotCountAsHealthy() {
        var script = Script()
        Self.untimed(&script, StateHealth(simStalled: true))
        for _ in 0..<5 { Self.untimed(&script, StateHealth(simStalled: false, loopAgeMs: 2500)) }
        XCTAssertTrue(script.detector.stalled, "a loop 2.5 s old is not running, whatever the flag")
        // On a server that once sent the flag, a state without it says nothing.
        for _ in 0..<5 { Self.untimed(&script, StateHealth()) }
        XCTAssertTrue(script.detector.stalled)
    }

    // MARK: The app in the background

    func testTimeInTheBackgroundDoesNotCountTowardNotResponding() {
        var script = Script()
        _ = script.fresh()
        frozenStream(&script, count: 3)
        let pausedAt = script.now
        _ = script.at(pausedAt + 2000, .background)
        XCTAssertEqual(script.at(pausedAt + 40_000, .tick).level, .paused, "no judging while away")
        _ = script.at(pausedAt + 40_000, .foreground)
        XCTAssertEqual(script.at(pausedAt + 40_001, .tick).level, .paused, "2 s in the foreground so far")
        // Fresh evidence decides: the loop ran on meanwhile.
        _ = script.fresh()
        _ = script.fresh()
        XCTAssertEqual(script.fresh().level, .running)
    }

    func testTimeInTheForegroundStillCountsAfterABackgroundSpell() {
        var script = Script()
        _ = script.fresh()
        frozenStream(&script, count: 3)
        let pausedAt = script.now
        _ = script.at(pausedAt + 10_000, .background)
        _ = script.at(pausedAt + 30_000, .foreground)
        XCTAssertEqual(script.at(pausedAt + 34_999, .tick).level, .paused, "14.999 s in the foreground")
        XCTAssertEqual(script.at(pausedAt + 35_000, .tick).level, .notResponding, "15 s in the foreground")
    }

    func testBusyAndUnansweredStopsWaitWhileInTheBackground() {
        var busy = Script()
        _ = busy.fresh()
        _ = busy.at(1000, .refused(request: "pose_start", reason: "busy"))
        _ = busy.at(2000, .background)
        XCTAssertFalse(busy.at(20_000, .tick).stalled)
        _ = busy.at(20_000, .foreground)
        XCTAssertFalse(busy.at(22_000, .tick).stalled, "busy for 3 s in the foreground, not more")
        XCTAssertTrue(busy.at(22_001, .tick).stalled)
        var stop = Script()
        _ = stop.fresh()
        _ = stop.at(1000, .stopSent(start: 8))
        _ = stop.at(2000, .background)
        _ = stop.at(20_000, .foreground)
        XCTAssertFalse(stop.at(21_999, .tick).stalled)
        XCTAssertEqual(stop.at(22_000, .tick).trigger, .stopUnanswered)
    }

    /// A state can still arrive while the app is away. It raises nothing, not even to not responding at once with an
    /// old loop; after the return, fresh evidence decides either way.
    func testAStateHeardInTheBackgroundRaisesNothing() {
        var detector = SimStallDetector()
        detector.observe(.state(StateHealth(simStalled: true, loopAgeMs: 1000)), at: 0)
        XCTAssertEqual(detector.level, .paused)
        detector.observe(.background, at: 1000)
        detector.observe(.state(StateHealth(simStalled: true, loopAgeMs: 16_000)), at: 15_000)
        XCTAssertEqual(detector.level, .paused, "only 1 s was spent waiting in the foreground")
        detector.observe(.refused(request: "pose_start", reason: "sim_stalled"), at: 15_100)
        XCTAssertEqual(detector.level, .paused)
        var running = SimStallDetector()
        running.observe(.state(StateHealth(simStalled: false)), at: 0)
        running.observe(.background, at: 100)
        running.observe(.state(StateHealth(simStalled: true, loopAgeMs: 16_000)), at: 5000)
        running.observe(.refused(request: "pose_start", reason: "sim_stalled"), at: 5100)
        XCTAssertEqual(running.level, .running, "nothing rises while away")
        // After the return, a state that says the loop is still old does count.
        detector.observe(.foreground, at: 20_000)
        XCTAssertEqual(detector.level, .paused)
        detector.observe(.state(StateHealth(simStalled: true, loopAgeMs: 21_000)), at: 20_200)
        XCTAssertEqual(detector.level, .notResponding)
        // And one that says the loop runs clears it, as before.
        running.observe(.foreground, at: 6000)
        running.observe(.state(StateHealth(simStalled: true, loopAgeMs: 1000)), at: 6200)
        XCTAssertEqual(running.level, .paused)
        for step in 1...SimStallDetector.freshStates {
            running.observe(.state(StateHealth(simStalled: false, loopAgeMs: 10)), at: 6200 + 200 * step)
        }
        XCTAssertEqual(running.level, .running)
    }

    // MARK: States that arrive late

    func testAStateOlderThanOneSeenSetsNoSign() {
        var script = Script()
        _ = script.fresh()
        let older = script.serverNs
        _ = script.fresh()
        // Late, from the other connection: written before the newest seen, and saying the loop stopped long ago.
        script.now += 5
        let late = StateHealth(
            capturedNs: older, sentNs: older + 5_000_000, simStalled: true, loopAgeMs: 16_000, resetting: true)
        script.detector.observe(.state(late), at: script.now)
        XCTAssertEqual(script.detector.level, .running, "an overtaken state says nothing new")
        // Nor did it start a reset's allowance: a sign right after it still counts.
        _ = script.at(script.now + 10, .refused(request: "pose_start", reason: "sim_stalled"))
        XCTAssertEqual(script.detector.level, .paused)
    }

    // MARK: Reading the state

    func testTheHealthFieldsAreReadFromAState() throws {
        let text = """
            {"estop": true, "sim_stalled": true, "loop_age_ms": 4567.5,
             "timing": {"state_id": 921224, "captured_monotonic_ns": 10127610818058821,
                        "sent_monotonic_ns": 10127684836678753, "server_clock_id": "x"}}
            """
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let health = StateHealth(payload: payload)
        XCTAssertEqual(health.simStalled, true)
        XCTAssertEqual(health.loopAgeMs, 4567.5)
        XCTAssertEqual(health.capturedNs, 10_127_610_818_058_821)
        XCTAssertEqual(health.ageMs, 74_018, "the 22:07:13 state: captured 74 s before it was sent")
    }

    func testAnOlderServerSendsNeitherNewField() throws {
        let text = """
            {"estop": false, "timing": {"captured_monotonic_ns": 5000000, "sent_monotonic_ns": 7000000}}
            """
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let health = StateHealth(payload: payload)
        XCTAssertNil(health.simStalled)
        XCTAssertNil(health.loopAgeMs)
        XCTAssertEqual(health.ageMs, 2)
        let wrong = StateHealth(payload: [
            "sim_stalled": 1, "loop_age_ms": true, "timing": ["captured_monotonic_ns": "1"],
        ])
        XCTAssertNil(wrong.simStalled, "only a JSON boolean")
        XCTAssertNil(wrong.loopAgeMs)
        XCTAssertNil(wrong.capturedNs)
    }
}
