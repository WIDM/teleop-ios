import XCTest
@testable import TeleopCore

/// The lowest rule, the guide's aid for an arm that cannot go lower: an arm that stands still in height while the
/// operator asks for lower is "lowest" in place of "blocked", also after a clamp, once per approach, sooner on a second
/// visit to the lowest height found, and that height (the gripper link's and the pinch point's) is kept until the next
/// welcome; "Blocked." stays silent while the operator asks for lower. Off, which is the default, every event is
/// version 1.0.1's.
final class FeedbackMonitorLowestTests: XCTestCase {
    private var monitor = FeedbackMonitor(limits: GripperLimits(openDeg: 97, emptyDeg: 2))
    /// Where the jaws stop on the table from the reset pose, gripper link, robot base frame.
    private let onTable = SIMD3(0.02, -0.14, 0.133)
    /// The pinch point there, robot base frame.
    private let pinchOnTable = SIMD3(0.027, -0.176, 0.045)
    /// A gripper link at height zero, so that how far below it a command is equals the command's own depth exactly.
    private let atZero = SIMD3(0.02, -0.14, 0.0)

    override func setUp() {
        monitor = FeedbackMonitor(limits: GripperLimits(openDeg: 97, emptyDeg: 2))
        monitor.reportsLowest = true
    }

    private func state(_ activity: ServerActivity? = .poseTracking, arm: SIMD3<Double>?) -> ServerState {
        ServerState(activity: activity, endEffector: arm)
    }

    /// States every 200 ms from `from` through `through`, the arm at `arm` and the command `gap` from it; the events.
    private func stand(
        at arm: SIMD3<Double>, commanded gap: SIMD3<Double>, from: Int, through: Int,
        activity: ServerActivity? = .poseTracking
    ) -> [(atMs: Int, event: FeedbackEvent)] {
        var events: [(atMs: Int, event: FeedbackEvent)] = []
        for t in stride(from: from, through: through, by: 200) {
            monitor.commanded(arm + gap)
            events += monitor.observe(state(activity, arm: arm), at: t).map { (t, $0) }
        }
        return events
    }

    func testAStallWithTheCommandBelowIsLowestNotBlocked() {
        monitor.startSent(.pose, restart: false, at: 0)
        let events = stand(at: onTable, commanded: SIMD3(0, 0, -0.02), from: 200, through: 1600)
        XCTAssertEqual(events.map(\.event), [.limit(.lowest)])
        XCTAssertGreaterThanOrEqual(events.first?.atMs ?? 0, 1200, "after a full second")
        XCTAssertEqual(monitor.lowestSeen, onTable.z)
    }

    /// Level: the blocked rule as before, and no lowest height.
    func testAStallWithTheCommandLevelIsBlocked() {
        for gap in [SIMD3(0.02, 0, 0), SIMD3(0, -0.03, 0)] {
            setUp()
            monitor.startSent(.pose, restart: false, at: 0)
            let events = stand(at: onTable, commanded: gap, from: 200, through: 1600)
            XCTAssertEqual(events.map(\.event), [.limit(.blocked)], "\(gap)")
            XCTAssertNil(monitor.lowestSeen, "\(gap)")
        }
    }

    /// The full stall is lowest only with the newest state commanded at least 10 mm below: 8 mm below and 7 mm across
    /// is under that and still 10 mm away, so it is the blocked rule's stall, and no lowest height is kept.
    func testAStallWithTheCommandMostlyBelowButUnderTenMillimetresBelowIsBlocked() {
        monitor.startSent(.pose, restart: false, at: 0)
        let events = stand(at: onTable, commanded: SIMD3(0.007, 0, -0.008), from: 200, through: 1600)
        XCTAssertEqual(events.map(\.event), [.limit(.blocked)])
        XCTAssertNil(monitor.lowestSeen)
    }

    /// Pushing down past the box's floor sets the clamp label; blocked is silenced by it, lowest is not.
    func testLowestIsToldAfterAClamp() {
        monitor.startSent(.pose, restart: false, at: 0)
        var events = stand(at: onTable, commanded: SIMD3(0, 0, -0.06), from: 200, through: 200)
        events += stand(
            at: onTable, commanded: SIMD3(0, 0, -0.06), from: 400, through: 1800, activity: .poseClamped)
        XCTAssertEqual(events.map(\.event), [.limit(.workspace), .limit(.lowest)])
    }

    /// Told once while the arm stays down, whatever it does under 10 mm up; armed again by rising 10 mm, and by a new
    /// start.
    func testOncePerApproach() {
        monitor.startSent(.pose, restart: false, at: 0)
        var events = stand(at: onTable, commanded: SIMD3(0, 0, -0.02), from: 200, through: 1600)
        events += stand(at: onTable + SIMD3(0, 0, 0.009), commanded: SIMD3(0, 0, 0.01), from: 1800, through: 2200)
        events += stand(at: onTable, commanded: SIMD3(0, 0, -0.02), from: 2400, through: 4400)
        XCTAssertEqual(events.map(\.event), [.limit(.lowest)], "9 mm up and back down is the same approach")

        events = stand(at: onTable + SIMD3(0, 0, 0.01), commanded: SIMD3(0, 0, 0.01), from: 4600, through: 4800)
        events += stand(at: onTable, commanded: SIMD3(0, 0, -0.02), from: 5000, through: 6000)
        XCTAssertEqual(events.map(\.event), [.limit(.lowest)], "10 mm up arms it again")

        monitor.released(.pose)
        monitor.startSent(.pose, restart: false, at: 7000)
        events = stand(at: onTable, commanded: SIMD3(0, 0, -0.02), from: 7200, through: 8600)
        XCTAssertEqual(events.map(\.event), [.limit(.lowest)], "a new start arms it again")

        // A resync's restart is the same hold.
        monitor.startSent(.pose, restart: true, at: 8800)
        events = stand(at: onTable, commanded: SIMD3(0, 0, -0.02), from: 9000, through: 10400)
        XCTAssertEqual(events.map(\.event), [])
    }

    /// Back at the lowest height found, the cue comes without the full second: within 2 mm of it, sent at least 5 mm
    /// lower, and under 1 mm of motion in 0.3 s, so with a state every 200 ms within 0.4 s of arriving.
    func testASecondVisitIsToldWithinFourTenthsOfASecond() throws {
        monitor.startSent(.pose, restart: false, at: 0)
        _ = stand(at: onTable, commanded: SIMD3(0, 0, -0.02), from: 200, through: 1600)
        monitor.released(.pose)
        monitor.startSent(.pose, restart: false, at: 2000)
        // Down from 3 cm up, 1 cm every state, then standing 1.5 mm above the lowest height, sent 6 mm lower.
        var events: [(atMs: Int, event: FeedbackEvent)] = []
        for (i, t) in stride(from: 2200, through: 2600, by: 200).enumerated() {
            let arm = onTable + SIMD3(0, 0, 0.03 - 0.01 * Double(i))
            events += stand(at: arm, commanded: SIMD3(0, 0, -0.01), from: t, through: t)
        }
        let arrived = 2800
        let near = onTable + SIMD3(0, 0, 0.0015)
        events += stand(at: near, commanded: SIMD3(0, 0, -0.006), from: arrived, through: 4000)
        XCTAssertEqual(events.map(\.event), [.limit(.lowest)])
        let told = try XCTUnwrap(events.first?.atMs)
        XCTAssertLessThanOrEqual(told - arrived, 400)
        XCTAssertGreaterThanOrEqual(told - arrived, FeedbackMonitor.lowestQuickMs)
    }

    /// Each number of the quicker stall, just outside: 2.5 mm from the lowest height, 4 mm below, 1.2 mm of motion.
    /// None of them is told before the full second, and the shallower command never is.
    func testTheQuickerStallNeedsEachOfItsNumbers() {
        let cases: [(above: Double, below: Double, wobble: Double, toldByMs: Int?)] = [
            (0.0025, 0.012, 0, 1000), (0.001, 0.004, 0, nil), (0.001, 0.012, 0.0012, 1000), (0.001, 0.012, 0, 400),
        ]
        for c in cases {
            setUp()
            monitor.startSent(.pose, restart: false, at: 0)
            _ = stand(at: onTable, commanded: SIMD3(0, 0, -0.02), from: 200, through: 1600)
            monitor.released(.pose)
            monitor.startSent(.pose, restart: false, at: 2000)
            var told: Int?
            for (i, t) in stride(from: 2200, through: 4400, by: 200).enumerated() where told == nil {
                // The wobble is up and down every state, never 2 mm: it is under the full stall's motion.
                let arm = onTable + SIMD3(0, 0, c.above + (i % 2 == 0 ? 0 : c.wobble))
                if !stand(at: arm, commanded: SIMD3(0, 0, -c.below), from: t, through: t).isEmpty { told = t - 2200 }
            }
            if let by = c.toldByMs {
                XCTAssertEqual(told, by, "\(c)")
            } else {
                XCTAssertNil(told, "\(c)")
            }
        }
    }

    /// Within 2 mm of the lowest height found counts below it as well as above: 1.5 mm below, sent 12 mm lower, is a
    /// second visit, told within 0.4 s; 2.5 mm below waits for the full second. Either way the lower height is then the
    /// lowest.
    func testTheQuickerStallIsWithinTwoMillimetresBelowTheLowestHeightToo() {
        for (below, toldByMs) in [(0.0015, 400), (0.0025, 1000)] {
            setUp()
            monitor.startSent(.pose, restart: false, at: 0)
            _ = stand(at: onTable, commanded: SIMD3(0, 0, -0.02), from: 200, through: 1600)
            monitor.released(.pose)
            monitor.startSent(.pose, restart: false, at: 2000)
            let lower = onTable - SIMD3(0, 0, below)
            let events = stand(at: lower, commanded: SIMD3(0, 0, -0.012), from: 2200, through: 4400)
            XCTAssertEqual(events.map(\.event), [.limit(.lowest)], "\(below)")
            XCTAssertEqual(events.first.map { $0.atMs - 2200 }, toldByMs, "\(below)")
            XCTAssertEqual(monitor.lowestSeen, lower.z, "\(below)")
        }
    }

    func testALowerStallReplacesTheLowestHeightAndAHigherOneDoesNot() {
        monitor.startSent(.pose, restart: false, at: 0)
        _ = stand(at: onTable, commanded: SIMD3(0, 0, -0.02), from: 200, through: 1600)
        XCTAssertEqual(monitor.lowestSeen, onTable.z)
        monitor.released(.pose)
        monitor.startSent(.pose, restart: false, at: 2000)
        _ = stand(at: onTable + SIMD3(0, 0, 0.02), commanded: SIMD3(0, 0, -0.02), from: 2200, through: 3600)
        XCTAssertEqual(monitor.lowestSeen, onTable.z, "on something 2 cm up: not lower")
        monitor.released(.pose)
        monitor.startSent(.pose, restart: false, at: 4000)
        _ = stand(at: onTable - SIMD3(0, 0, 0.005), commanded: SIMD3(0, 0, -0.02), from: 4200, through: 5600)
        XCTAssertEqual(monitor.lowestSeen, onTable.z - 0.005)
    }

    func testTheLowestHeightIsForgottenAtAWelcomeAndWithTheRuleOff() {
        monitor.startSent(.pose, restart: false, at: 0)
        _ = stand(at: onTable, commanded: SIMD3(0, 0, -0.02), from: 200, through: 1600)
        XCTAssertNotNil(monitor.lowestSeen)
        monitor.welcomed(session: "run-1")
        XCTAssertNil(monitor.lowestSeen, "a new welcome")
        monitor.startSent(.pose, restart: false, at: 2000)
        _ = stand(at: onTable, commanded: SIMD3(0, 0, -0.02), from: 2200, through: 3600)
        XCTAssertNotNil(monitor.lowestSeen)
        monitor.reportsLowest = false
        XCTAssertNil(monitor.lowestSeen, "the rule off")
    }

    /// The default, which every existing test and the aids-off path use: the same inputs give version 1.0.1's events,
    /// blocked once and silenced after a clamp, and no lowest height.
    func testTheDefaultIsOneZeroOne() {
        monitor = FeedbackMonitor(limits: GripperLimits(openDeg: 97, emptyDeg: 2))
        XCTAssertFalse(monitor.reportsLowest)
        monitor.startSent(.pose, restart: false, at: 0)
        var events = stand(at: onTable, commanded: SIMD3(0, 0, -0.02), from: 200, through: 4400)
        XCTAssertEqual(events.map(\.event), [.limit(.blocked)])
        monitor.released(.pose)
        monitor.startSent(.pose, restart: false, at: 5000)
        events = stand(at: onTable, commanded: SIMD3(0, 0, -0.06), from: 5200, through: 5200)
        events += stand(
            at: onTable, commanded: SIMD3(0, 0, -0.06), from: 5400, through: 6800, activity: .poseClamped)
        XCTAssertEqual(events.map(\.event), [.limit(.workspace)])
        XCTAssertNil(monitor.lowestSeen)
    }

    // The tests below give their inputs as a list, run once with the rule on, once with it off and once on version
    // 1.0.1's monitor: with the rule off, every one of them must give 1.0.1's events.

    /// One thing the link tells the monitor.
    private enum Input {
        case press(atMs: Int)
        case resync(atMs: Int)
        case command(SIMD3<Double>)
        case state(atMs: Int, ServerState)
        case release
        case welcome
        case linkClosed
        /// The aids turned off; nothing for a monitor without the rule.
        case ruleOff
    }

    /// An event and when it came.
    private struct Heard: Equatable {
        let atMs: Int
        let event: FeedbackEvent
    }

    private static let limits = GripperLimits(openDeg: 97, emptyDeg: 2)

    /// `inputs` on a monitor with the rule on or off: the events, and the monitor afterwards.
    private func run(_ inputs: [Input], lowest: Bool = true) -> (heard: [Heard], monitor: FeedbackMonitor) {
        var monitor = FeedbackMonitor(limits: Self.limits)
        monitor.reportsLowest = lowest
        var heard: [Heard] = []
        for input in inputs {
            switch input {
            case .press(let atMs): monitor.startSent(.pose, restart: false, at: atMs)
            case .resync(let atMs): monitor.startSent(.pose, restart: true, at: atMs)
            case .command(let point): monitor.commanded(point)
            case .state(let atMs, let state):
                heard += monitor.observe(state, at: atMs).map { Heard(atMs: atMs, event: $0) }
            case .release: monitor.released(.pose)
            case .welcome: monitor.welcomed(session: "run-1")
            case .linkClosed: monitor.linkClosed()
            case .ruleOff: monitor.reportsLowest = false
            }
        }
        return (heard, monitor)
    }

    /// `inputs` on version 1.0.1's monitor.
    private func run101(_ inputs: [Input]) -> [Heard] {
        var monitor = FeedbackMonitor101(limits: Self.limits)
        var heard: [Heard] = []
        for input in inputs {
            switch input {
            case .press(let atMs): monitor.startSent(.pose, restart: false, at: atMs)
            case .resync(let atMs): monitor.startSent(.pose, restart: true, at: atMs)
            case .command(let point): monitor.commanded(point)
            case .state(let atMs, let state):
                heard += monitor.observe(state, at: atMs).map { Heard(atMs: atMs, event: $0) }
            case .release: monitor.released(.pose)
            case .welcome: monitor.welcomed(session: "run-1")
            case .linkClosed: monitor.linkClosed()
            case .ruleOff: break
            }
        }
        return heard
    }

    /// The events with the rule on, once the same inputs with it off have given version 1.0.1's events.
    private func told(_ inputs: [Input], file: StaticString = #filePath, line: UInt = #line) -> [Heard] {
        XCTAssertEqual(
            run(inputs, lowest: false).heard, run101(inputs), "with the rule off, version 1.0.1's", file: file,
            line: line)
        return run(inputs).heard
    }

    /// A state at each of `times`, each after its command: the gripper link at `arm(t)`, the pinch point at `pinch(t)`
    /// (nil: not reported), and the command `gap(t)` from the gripper link.
    private func states(
        at times: [Int], arm: (Int) -> SIMD3<Double>, pinch: (Int) -> SIMD3<Double>? = { _ in nil },
        gap: (Int) -> SIMD3<Double>
    ) -> [Input] {
        times.flatMap { t -> [Input] in
            let state = ServerState(activity: .poseTracking, endEffector: arm(t), toolPoint: pinch(t))
            return [.command(arm(t) + gap(t)), .state(atMs: t, state)]
        }
    }

    /// Every 200 ms from `from` through `through`.
    private func every(from: Int, through: Int) -> [Int] { Array(stride(from: from, through: through, by: 200)) }
    private func down(_ meters: Double) -> SIMD3<Double> { SIMD3(0, 0, -meters) }
    private func up(_ meters: Double) -> SIMD3<Double> { SIMD3(0, 0, meters) }
    private func lowest(at atMs: Int) -> Heard { Heard(atMs: atMs, event: .limit(.lowest)) }
    private func blocked(at atMs: Int) -> Heard { Heard(atMs: atMs, event: .limit(.blocked)) }

    /// An arm on a table slides along it as the hand pushes down and across: never still in all three directions, but
    /// still in height. Asked 12 mm lower all along, it is told as soon as a second of states has been judged.
    func testAnArmSlidingAlongTheTableIsToldAfterASecond() {
        let start = onTable
        let sliding = { (t: Int) in start + SIMD3(0.004 * Double(t / 200), 0, 0) }
        let inputs: [Input] =
            [.press(atMs: 0)]
            + states(at: every(from: 200, through: 2000), arm: sliding, gap: { _ in SIMD3(0.004, 0, -0.012) })
        XCTAssertEqual(told(inputs), [lowest(at: 1200)])
        XCTAssertEqual(run(inputs).monitor.lowestSeen, onTable.z)
    }

    /// No direction is asked for: a push into the table that is mostly sideways stops the arm as surely.
    func testADiagonalAskIsTold() {
        for gap in [SIMD3(0.04, 0, -0.012), SIMD3(0.03, 0, -0.015), SIMD3(0.012, -0.012, -0.0119)] {
            let inputs: [Input] =
                [.press(atMs: 0)]
                + states(at: every(from: 200, through: 1600), arm: { _ in onTable }, gap: { _ in gap })
            XCTAssertEqual(told(inputs), [lowest(at: 1200)], "\(gap)")
        }
    }

    /// The full stall needs the newest state commanded at least 10 mm lower: after a second asked 12 mm lower, a newest
    /// state asked 9.9 mm lower, and those after it, give nothing; at exactly 10 mm it is told.
    func testTheNewestStateUnderTenMillimetresBelowGivesNothing() {
        for (newest, heard) in [(0.0099, [Heard]()), (0.010, [lowest(at: 1200)])] {
            let inputs: [Input] =
                [.press(atMs: 0)]
                + states(at: every(from: 200, through: 1000), arm: { _ in atZero }, gap: { _ in down(0.012) })
                + states(at: every(from: 1200, through: 2400), arm: { _ in atZero }, gap: { _ in down(newest) })
            XCTAssertEqual(told(inputs), heard, "\(newest)")
        }
    }

    /// Every state of the full stall's second must have been commanded at least 5 mm lower, the oldest too: one at
    /// 4.9 mm, first or in the middle, gives nothing, and so does a first state that came before any command; at
    /// exactly 5 mm the same states are told.
    func testOneStateOfTheSecondUnderFiveMillimetresBelowGivesNothing() {
        let cases: [(atMs: Int, depth: Double, heard: [Heard])] = [
            (200, 0.0049, []), (600, 0.0049, []), (200, 0.005, [lowest(at: 1200)]), (600, 0.005, [lowest(at: 1200)]),
        ]
        for c in cases {
            let inputs: [Input] =
                [.press(atMs: 0)]
                + states(
                    at: every(from: 200, through: 1200), arm: { _ in atZero },
                    gap: { t in down(t == c.atMs ? c.depth : 0.012) })
            XCTAssertEqual(told(inputs), c.heard, "\(c.depth) at \(c.atMs)")
        }
        let beforeAnyCommand: [Input] =
            [.press(atMs: 0), .state(atMs: 200, ServerState(activity: .poseTracking, endEffector: atZero))]
            + states(at: every(from: 400, through: 1200), arm: { _ in atZero }, gap: { _ in down(0.012) })
        XCTAssertEqual(told(beforeAnyCommand), [])
    }

    /// A window is judged only over states that arrived regularly: 401 ms between two states inside the full stall's
    /// second gives nothing, 400 ms is told. The same inside the quicker stall's 0.3 s.
    func testAnArrivalGapOverFourHundredMillisecondsGivesNothing() {
        for gap in [401, 400] {
            let inputs: [Input] =
                [.press(atMs: 0)]
                + states(at: [200, 400, 600, 600 + gap, 800 + gap], arm: { _ in onTable }, gap: { _ in down(0.012) })
            XCTAssertEqual(told(inputs), gap > 400 ? [] : [lowest(at: 1200)], "\(gap)")
        }
        for gap in [401, 400] {
            // A first press finds the lowest height; the second comes back to it.
            let inputs: [Input] =
                [.press(atMs: 0)]
                + states(at: every(from: 200, through: 1600), arm: { _ in onTable }, gap: { _ in down(0.012) })
                + [.release, .press(atMs: 2000)]
                + states(at: [2200, 2200 + gap], arm: { _ in onTable }, gap: { _ in down(0.012) })
            XCTAssertEqual(told(inputs), [lowest(at: 1200)] + (gap > 400 ? [] : [lowest(at: 2600)]), "\(gap)")
        }
    }

    /// Each state keeps the command it arrived with: after a second commanded level, a command 12 mm lower is told only
    /// once a whole second of states has asked, not as soon as the newest does.
    func testALevelSecondThenAnAskForLowerWaitsForAWholeSecondOfAsking() {
        let inputs: [Input] =
            [.press(atMs: 0)]
            + states(at: every(from: 200, through: 1200), arm: { _ in onTable }, gap: { _ in .zero })
            + states(at: every(from: 1400, through: 3000), arm: { _ in onTable }, gap: { _ in down(0.012) })
        XCTAssertEqual(told(inputs), [lowest(at: 2400)])
    }

    /// The height is the pinch point's when every state of the window carries it: the gripper link rising and falling
    /// 3 mm with the arm's posture while the pinch point stays on the table is told. With one state of the window
    /// without the pinch point, the window is judged by the gripper link, which is not still.
    func testThePinchHeightIsJudgedWhenEveryStateCarriesIt() {
        let start = onTable
        let posture = { (t: Int) in start + SIMD3(0, 0, (t / 200) % 2 == 0 ? 0.003 : 0) }
        for missingAt in [nil, 600] {
            let inputs: [Input] =
                [.press(atMs: 0)]
                + states(
                    at: every(from: 200, through: 1600), arm: posture,
                    pinch: { t in t == missingAt ? nil : pinchOnTable }, gap: { _ in down(0.012) })
            XCTAssertEqual(told(inputs), missingAt == nil ? [lowest(at: 1200)] : [], "\(String(describing: missingAt))")
        }
    }

    /// The quicker stall compares the height with the lowest one found of the same kind. Back with the pinch point
    /// 1.5 mm above where it stood and the gripper link 10 mm higher in another posture, asked 5 mm lower: told within
    /// 0.4 s. At the gripper link's height of the first visit but with the pinch point 4 mm higher, it is a new height:
    /// nothing.
    func testTheQuickerStallFollowsThePinchPointsLowestHeight() {
        // The second visit's gripper link is at height zero, so 5 mm below it is exactly 5 mm.
        let firstArm = atZero - up(0.010)
        let firstPinch = SIMD3(0.027, -0.176, -0.098)
        let first: [Input] =
            [.press(atMs: 0)]
            + states(
                at: every(from: 200, through: 1600), arm: { _ in firstArm }, pinch: { _ in firstPinch },
                gap: { _ in down(0.012) })
            + [.release, .press(atMs: 2000)]
        let back =
            first
            + states(
                at: every(from: 2200, through: 3000), arm: { _ in atZero }, pinch: { _ in firstPinch + up(0.0015) },
                gap: { _ in down(0.005) })
        XCTAssertEqual(told(back), [lowest(at: 1200), lowest(at: 2600)])
        let after = run(back).monitor
        XCTAssertEqual(after.lowestPinchSeen, firstPinch.z)
        XCTAssertEqual(after.lowestSeen, firstArm.z)
        let higher =
            first
            + states(
                at: every(from: 2200, through: 4400), arm: { _ in firstArm }, pinch: { _ in firstPinch + up(0.004) },
                gap: { _ in down(0.008) })
        XCTAssertEqual(told(higher), [lowest(at: 1200)])
    }

    /// Both lowest heights come from every stall, told or not, each keeping its own lowest, the pinch point's only from
    /// states that carry it. A new press, a resync and a closed link keep them; a welcome forgets both, and so does
    /// turning the rule off.
    func testBothLowestHeightsAreKeptAndForgottenTogether() {
        func stall(from: Int, arm: SIMD3<Double>, pinch: SIMD3<Double>?) -> [Input] {
            states(
                at: every(from: from, through: from + 1400), arm: { _ in arm }, pinch: { _ in pinch },
                gap: { _ in down(0.012) })
        }
        XCTAssertNil(run([]).monitor.lowestSeen)
        XCTAssertNil(run([]).monitor.lowestPinchSeen)
        var inputs: [Input] = [.press(atMs: 0)] + stall(from: 200, arm: onTable, pinch: nil)
        XCTAssertEqual(run(inputs).monitor.lowestSeen, onTable.z)
        XCTAssertNil(run(inputs).monitor.lowestPinchSeen, "no state carried the pinch point")
        // The gripper link higher, with a pinch point: the gripper link's lowest stays, the pinch point's is set.
        inputs += [.release, .press(atMs: 2000)] + stall(from: 2200, arm: onTable + up(0.007), pinch: pinchOnTable)
        XCTAssertEqual(run(inputs).monitor.lowestSeen, onTable.z)
        XCTAssertEqual(run(inputs).monitor.lowestPinchSeen, pinchOnTable.z)
        // The gripper link lower and the pinch point higher: each keeps its own lowest.
        inputs += [.release, .press(atMs: 4000)]
        inputs += stall(from: 4200, arm: onTable - up(0.003), pinch: pinchOnTable + up(0.003))
        XCTAssertEqual(run(inputs).monitor.lowestSeen, onTable.z - 0.003)
        XCTAssertEqual(run(inputs).monitor.lowestPinchSeen, pinchOnTable.z)
        // Told there; then lower again in the same approach, the gripper link by 1 mm and the pinch point to 1 mm under
        // its lowest, is not told again, but both heights follow it.
        XCTAssertEqual(told(inputs).count, 3)
        inputs += stall(from: 5800, arm: onTable - up(0.004), pinch: pinchOnTable - up(0.001))
        XCTAssertEqual(told(inputs).count, 3)
        XCTAssertEqual(run(inputs).monitor.lowestSeen, onTable.z - 0.004)
        XCTAssertEqual(run(inputs).monitor.lowestPinchSeen, pinchOnTable.z - 0.001)
        inputs += [.resync(atMs: 7400), .release, .press(atMs: 7600), .linkClosed]
        XCTAssertEqual(run(inputs).monitor.lowestSeen, onTable.z - 0.004, "kept")
        XCTAssertEqual(run(inputs).monitor.lowestPinchSeen, pinchOnTable.z - 0.001, "kept")
        inputs += [.welcome]
        XCTAssertNil(run(inputs).monitor.lowestSeen, "a welcome")
        XCTAssertNil(run(inputs).monitor.lowestPinchSeen, "a welcome")
        inputs += [.press(atMs: 8000)] + stall(from: 8200, arm: onTable, pinch: pinchOnTable)
        XCTAssertEqual(run(inputs).monitor.lowestSeen, onTable.z)
        XCTAssertEqual(run(inputs).monitor.lowestPinchSeen, pinchOnTable.z)
        inputs += [.ruleOff]
        XCTAssertNil(run(inputs).monitor.lowestSeen, "the rule off")
        XCTAssertNil(run(inputs).monitor.lowestPinchSeen, "the rule off")
        XCTAssertEqual(told(inputs).count, 4)
    }

    /// Once per approach, judged on the kind of height the cue was told by. Told by the pinch point: the pinch point
    /// 9.9 mm up does not arm it again although the gripper link rose 15 mm, 10 mm up does. Once the pinch point is no
    /// longer reported, the gripper link's rise counts: 9 mm does not arm it, 10 mm does. A resync does not, a new
    /// press does.
    func testOncePerApproachIsJudgedOnTheHeightItWasToldBy() {
        func at(_ from: Int, _ through: Int, rise: Double, pinchRise: Double?, gap: SIMD3<Double>) -> [Input] {
            states(
                at: every(from: from, through: through), arm: { _ in onTable + up(rise) },
                pinch: { _ in pinchRise.map { pinchOnTable + up($0) } }, gap: { _ in gap })
        }
        var inputs: [Input] = [.press(atMs: 0)] + at(200, 1200, rise: 0, pinchRise: 0, gap: down(0.012))
        inputs += at(1400, 1800, rise: 0.015, pinchRise: 0.0099, gap: up(0.01))
        inputs += at(2000, 3000, rise: 0, pinchRise: 0, gap: down(0.012))
        XCTAssertEqual(told(inputs), [lowest(at: 1200)], "the pinch point 9.9 mm up is the same approach")
        inputs += at(3200, 3400, rise: 0.015, pinchRise: 0.010, gap: up(0.01))
        inputs += at(3600, 4400, rise: 0, pinchRise: 0, gap: down(0.012))
        XCTAssertEqual(told(inputs), [lowest(at: 1200), lowest(at: 4000)], "the pinch point 10 mm up arms it again")
        inputs += at(4600, 4800, rise: 0.009, pinchRise: nil, gap: up(0.01))
        inputs += at(5000, 5800, rise: 0, pinchRise: nil, gap: down(0.012))
        XCTAssertEqual(told(inputs).count, 2, "without the pinch point, the gripper link 9 mm up is the same approach")
        inputs += at(6000, 6200, rise: 0.010, pinchRise: nil, gap: up(0.01))
        inputs += at(6400, 7200, rise: 0, pinchRise: nil, gap: down(0.012))
        XCTAssertEqual(told(inputs).last, lowest(at: 6800), "without the pinch point, the gripper link 10 mm up")
        inputs += [.resync(atMs: 7400)] + at(7600, 8600, rise: 0, pinchRise: nil, gap: down(0.012))
        XCTAssertEqual(told(inputs).count, 3, "a resync is the same press")
        inputs += [.release, .press(atMs: 8800)] + at(9000, 9400, rise: 0, pinchRise: nil, gap: down(0.012))
        XCTAssertEqual(told(inputs).last, lowest(at: 9400), "a new press")
    }

    /// "Blocked." stays silent while any state of its second was commanded at least 10 mm lower: the operator is asking
    /// for lower, and the lowest rule answers. A press that starts at rest on the table, its first state before the
    /// hand has moved, and is then asked 12 mm lower gives "lowest" only; so does a hand wavering 3 mm around 12 mm
    /// lower and 5 mm to the side, whose newest state is at times under 10 mm.
    func testBlockedIsSilentWhileTheOperatorAsksForLower() {
        let atRest: [Input] =
            [.press(atMs: 0)]
            + states(
                at: every(from: 200, through: 2000), arm: { _ in onTable },
                gap: { t in t == 200 ? .zero : down(0.012) })
        XCTAssertEqual(told(atRest), [lowest(at: 1400)])
        let waver = [0.012, 0.015, 0.009]
        let wavering: [Input] =
            [.press(atMs: 0)]
            + states(
                at: every(from: 200, through: 2000), arm: { _ in onTable },
                gap: { t in SIMD3(0.005, 0, -waver[(t / 200 - 1) % 3]) })
        XCTAssertEqual(told(wavering), [lowest(at: 1400)])
    }

    /// A stall against a wall with the hand a little low, commanded 8 mm below and 30 mm to the side, is not an ask for
    /// lower: "Blocked." is told.
    func testAStallAgainstAWallStillSaysBlocked() {
        let inputs: [Input] =
            [.press(atMs: 0)]
            + states(at: every(from: 200, through: 1600), arm: { _ in onTable }, gap: { _ in SIMD3(0.03, 0, -0.008) })
        XCTAssertEqual(told(inputs), [blocked(at: 1200)])
    }

    /// With the rule on, "Blocked." too is judged only over states that arrived regularly: 401 ms between two states
    /// inside its second gives nothing, where version 1.0.1 says "Blocked."; 400 ms is told.
    func testABlockedWindowWithAnArrivalGapOverFourHundredMillisecondsSaysNothing() {
        for gap in [401, 400] {
            let inputs: [Input] =
                [.press(atMs: 0)]
                + states(
                    at: [200, 400, 600, 600 + gap, 800 + gap], arm: { _ in onTable }, gap: { _ in SIMD3(0.02, 0, 0) })
            XCTAssertEqual(told(inputs), gap > 400 ? [] : [blocked(at: 800 + gap)], "\(gap)")
            XCTAssertEqual(run(inputs, lowest: false).heard, [blocked(at: 800 + gap)], "off, \(gap)")
        }
    }

    /// A told lowest is the hold's blocked cue as well: the same hold then held level against something 20 mm to the
    /// side is not told "Blocked.", where a new hold doing the same is.
    func testAToldLowestUsesUpTheHoldsBlockedCue() {
        let inputs: [Input] =
            [.press(atMs: 0)]
            + states(at: every(from: 200, through: 1200), arm: { _ in onTable }, gap: { _ in down(0.012) })
            + states(at: every(from: 1400, through: 3400), arm: { _ in onTable }, gap: { _ in SIMD3(0.02, 0, 0) })
            + [.release, .press(atMs: 3600)]
            + states(at: every(from: 3800, through: 5000), arm: { _ in onTable }, gap: { _ in SIMD3(0.02, 0, 0) })
        XCTAssertEqual(told(inputs), [lowest(at: 1200), blocked(at: 4800)])
    }
}
