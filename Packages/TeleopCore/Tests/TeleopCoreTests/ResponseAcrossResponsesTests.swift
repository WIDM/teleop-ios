import XCTest
import simd

@testable import TeleopCore

/// The blocked rule and the lowest rule run once per response: the SO-101's and bench arm B's (`TestResponse`: twice as
/// fast, so every distance, window and rate is different). Each case is built from the profile's own numbers, a place
/// just inside or just outside one of them, and states what the SO-101's own tests state: so what holds for B is what
/// holds for the SO-101 with B's numbers in it. A rule that read one number from the SO-101 would give B's case a
/// different answer.
final class ResponseAcrossResponsesTests: XCTestCase {
    /// Where the jaws stop on the table from the reset pose, gripper link, robot base frame.
    private let onTable = SIMD3(0.02, -0.14, 0.133)
    /// A box so large that it clamps no command.
    private let wholeRoom: (low: SIMD3<Double>, high: SIMD3<Double>) = (SIMD3(repeating: -10), SIMD3(repeating: 10))
    /// The states of every case arrive this often, under every response's arrival gap.
    private let stepMs = 100

    private func monitor(
        _ blocked: BlockedRule, _ lowest: LowestRule, reportsLowest: Bool = false,
        box: (low: SIMD3<Double>, high: SIMD3<Double>)? = nil
    ) -> FeedbackMonitor {
        var monitor = FeedbackMonitor(
            limits: TestJaw.so101.limits, frames: TestFrames.so101, blocked: blocked, lowest: lowest)
        monitor.reportsLowest = reportsLowest
        monitor.blockedWorkspace = box
        monitor.startSent(.pose, restart: false, at: 0)
        return monitor
    }

    private struct Step {
        var atMs: Int
        var arm: SIMD3<Double>?
        /// Where the command is, absolute.
        var command: SIMD3<Double>
    }

    /// The events each step of `steps` gave, in order.
    private func events(_ monitor: inout FeedbackMonitor, _ steps: [Step]) -> [(atMs: Int, event: FeedbackEvent)] {
        var heard: [(atMs: Int, event: FeedbackEvent)] = []
        for step in steps {
            monitor.commanded(step.command)
            let state = ServerState(activity: .poseTracking, endEffector: step.arm)
            heard += monitor.observe(state, at: step.atMs).map { (step.atMs, $0) }
        }
        return heard
    }

    /// Steps every `stepMs` from one step through `through`, the arm and the command by their own functions of time.
    private func steps(
        through: Int, arm: (Int) -> SIMD3<Double>, command: (Int, SIMD3<Double>) -> SIMD3<Double>
    ) -> [Step] {
        stride(from: stepMs, through: through, by: stepMs).map { t in
            let at = arm(t)
            return Step(atMs: t, arm: at, command: command(t, at))
        }
    }

    private func blockedTimes(_ heard: [(atMs: Int, event: FeedbackEvent)]) -> [Int] {
        heard.filter { $0.event == .limit(.blocked) }.map(\.atMs)
    }

    private func lowestTimes(_ heard: [(atMs: Int, event: FeedbackEvent)]) -> [Int] {
        heard.filter { $0.event == .limit(.lowest) }.map(\.atMs)
    }

    func testBenchBDiffersFromTheSO101InEveryNumberOfTheTwoRules() {
        let a = TestResponse.so101Blocked, b = TestResponse.benchBBlocked
        XCTAssertNotEqual(a.shortM, b.shortM)
        XCTAssertNotEqual(a.movedM, b.movedM)
        XCTAssertNotEqual(a.windowMs, b.windowMs)
        XCTAssertNotEqual(a.freshMs, b.freshMs)
        XCTAssertNotEqual(a.arrivalGapMs, b.arrivalGapMs)
        XCTAssertNotEqual(a.exclusionM, b.exclusionM)
        XCTAssertNotEqual(a.followingShare, b.followingShare)
        XCTAssertNotEqual(a.sameWayDeg, b.sameWayDeg)
        let c = TestResponse.so101Lowest, d = TestResponse.benchBLowest
        XCTAssertNotEqual(c.sustainM, d.sustainM)
        XCTAssertNotEqual(c.quickShortM, d.quickShortM)
        XCTAssertNotEqual(c.quickMovedM, d.quickMovedM)
        XCTAssertNotEqual(c.quickMs, d.quickMs)
        XCTAssertNotEqual(c.descentMps, d.descentMps)
    }

    // MARK: Blocked, on the gripper link's path with no work box

    /// An arm that stands still while the command is `short` ahead: told after a whole window, and only when the lead
    /// is at least the rule's short distance.
    func testTheBlockedRuleNeedsItsShortDistanceAndItsWindow() {
        for (name, blocked, lowest) in TestResponse.all {
            for (share, expectBlocked) in [(0.9, false), (1.1, true)] {
                var monitor = monitor(blocked, lowest)
                let run = steps(
                    through: 3 * blocked.windowMs, arm: { _ in onTable },
                    command: { _, arm in arm + SIMD3(0, 0, -blocked.shortM * share) })
                let times = blockedTimes(events(&monitor, run))
                XCTAssertEqual(times.count, expectBlocked ? 1 : 0, "\(name) \(share)")
                if let first = times.first {
                    XCTAssertGreaterThanOrEqual(first, blocked.windowMs, "\(name): after a whole window")
                    XCTAssertLessThanOrEqual(first, blocked.windowMs + 2 * stepMs, "\(name): and then at once")
                }
            }
        }
    }

    /// The arm counts as standing still when it moved less than the rule's moved distance over the window.
    func testTheBlockedRuleNeedsLessMotionThanItsMovedDistanceInAWindow() {
        for (name, blocked, lowest) in TestResponse.all {
            for (share, expectBlocked) in [(0.7, true), (1.3, false)] {
                var monitor = monitor(blocked, lowest)
                let perMs = blocked.movedM * share / Double(blocked.windowMs)
                let run = steps(
                    through: 3 * blocked.windowMs,
                    arm: { onTable + SIMD3(0, 0, -perMs * Double($0)) },
                    command: { _, arm in arm + SIMD3(0, 0, -3 * blocked.shortM) })
                XCTAssertEqual(
                    blockedTimes(events(&monitor, run)).count, expectBlocked ? 1 : 0, "\(name) \(share)")
            }
        }
    }

    /// A measurement older than the rule's freshness says nothing about now: a command that jumps ahead of an arm that
    /// stood still is told only while the newest position is fresher than that.
    func testTheBlockedRuleReadsNoPositionOlderThanItsFreshness() {
        for (name, blocked, lowest) in TestResponse.all {
            for (extraMs, expectBlocked) in [(-1, true), (0, false)] {
                var monitor = monitor(blocked, lowest)
                let stillUntil = blocked.windowMs + 2 * stepMs
                var run = steps(through: stillUntil, arm: { _ in onTable }, command: { _, arm in arm })
                // The command jumps far ahead while no state carries a position.
                run.append(
                    Step(
                        atMs: stillUntil + blocked.freshMs + extraMs, arm: nil,
                        command: onTable + SIMD3(0, 0, -3 * blocked.shortM)))
                XCTAssertEqual(blockedTimes(events(&monitor, run)).count, expectBlocked ? 1 : 0, "\(name) \(extraMs)")
            }
        }
    }

    // MARK: Blocked, by the direction asked (with a work box)

    /// Steps of a stationary or moving arm and a command, for the directional rule.
    private func directional(
        _ blocked: BlockedRule, _ lowest: LowestRule, through: Int? = nil, arm: (Int) -> SIMD3<Double>,
        command: (Int, SIMD3<Double>) -> SIMD3<Double>
    ) -> [Int] {
        var monitor = monitor(blocked, lowest, box: wholeRoom)
        let run = steps(through: through ?? 2 * blocked.windowMs + stepMs, arm: arm, command: command)
        return blockedTimes(events(&monitor, run))
    }

    /// A state from the arm at rest with the command a lead ahead: the same Blocked as without a box, once the arm
    /// has stood a whole window.
    func testTheDirectionalRuleToldAStandingArmAfterAWindow() {
        for (name, blocked, lowest) in TestResponse.all {
            let times = directional(
                blocked, lowest, arm: { _ in onTable },
                command: { _, arm in arm + SIMD3(0.4, 0, 0) })
            XCTAssertEqual(times.count, 1, name)
            XCTAssertGreaterThanOrEqual(times.first ?? 0, blocked.windowMs, name)
        }
    }

    /// An arm that made less progress along the lead than the lesser of the moved distance and the share of the lead is
    /// not following it; one that made more is.
    func testTheDirectionalRuleNeedsLessProgressThanTheLeadProgressShare() {
        for (name, blocked, lowest) in TestResponse.all {
            let lead = 1.25 * blocked.shortM
            let threshold = min(blocked.movedM, lead * blocked.leadProgressShare)
            XCTAssertLessThan(lead * blocked.leadProgressShare, blocked.movedM, "\(name): the share decides here")
            for (share, expectBlocked) in [(0.8, true), (1.2, false)] {
                let perMs = threshold * share / Double(blocked.windowMs)
                let times = directional(
                    blocked, lowest,
                    arm: { onTable + SIMD3(perMs * Double($0), 0, 0) },
                    command: { _, _ in onTable + SIMD3(lead, 0, 0) })
                XCTAssertEqual(times.count, expectBlocked ? 1 : 0, "\(name) \(share)")
            }
        }
    }

    /// An arm that moved the exclusion distance across the lead is moving, not held back.
    func testTheDirectionalRuleIsSilentForAnArmThatMovedItsExclusionDistance() {
        for (name, blocked, lowest) in TestResponse.all {
            let lead = 10 * blocked.exclusionM
            for (share, expectBlocked) in [(0.9, true), (1.1, false)] {
                let perMs = blocked.exclusionM * share / Double(blocked.windowMs)
                let times = directional(
                    blocked, lowest,
                    arm: { onTable + SIMD3(0, perMs * Double($0), 0) },
                    command: { _, _ in onTable + SIMD3(lead, 0, 0) })
                XCTAssertEqual(times.count, expectBlocked ? 1 : 0, "\(name) \(share)")
            }
        }
    }

    /// A command that travels while the arm follows it at least the following share of the way is followed; one that
    /// the arm follows less than that is not.
    func testTheDirectionalRuleNeedsTheArmToFollowTheCommandsTravelByItsShare() {
        for (name, blocked, lowest) in TestResponse.all {
            let travel = blocked.exclusionM
            let lead = 10 * travel
            for (share, expectBlocked) in [(0.8, true), (1.2, false)] {
                let armPerMs = travel * blocked.followingShare * share / Double(blocked.windowMs)
                let commandPerMs = travel / Double(blocked.windowMs)
                let times = directional(
                    blocked, lowest,
                    arm: { onTable + SIMD3(armPerMs * Double($0), 0, 0) },
                    command: { t, _ in onTable + SIMD3(commandPerMs * Double(t), lead, 0) })
                XCTAssertEqual(times.count, expectBlocked ? 1 : 0, "\(name) \(share)")
            }
        }
    }

    /// A lead that turns by less than the same-way angle over the window is one request; a lead that turns by more is
    /// a new one, and an arm that has not followed a changing request is not blocked.
    func testTheDirectionalRuleReadsALeadThatTurnsLessThanItsAngleAsTheSameRequest() {
        for (name, blocked, lowest) in TestResponse.all {
            for (share, expectBlocked) in [(0.9, true), (1.1, false)] {
                let turn = blocked.sameWayDeg * share * .pi / 180
                let times = directional(
                    blocked, lowest, arm: { _ in onTable },
                    command: { t, _ in
                        let angle = turn * Double(t) / Double(blocked.windowMs)
                        return onTable + 0.1 * SIMD3(cos(angle), sin(angle), 0)
                    })
                XCTAssertEqual(times.count, expectBlocked ? 1 : 0, "\(name) \(share)")
            }
        }
    }

    /// The SO-101's 45 degrees gives the same answer, to the last bit, as the form the monitor always used
    /// (`sqrt(aa * bb * 0.5)`): two leads where the cosine form `sqrt(aa * bb) * cos(45 deg)` says the other thing.
    func testTheSO101SameWayTestGivesTheAnswersOfTheFormItAlwaysUsed() {
        let rule = TestResponse.so101Blocked
        XCTAssertEqual(rule.sameWayCosineSquared, 0.5)
        let pairs: [(SIMD3<Double>, SIMD3<Double>)] = [
            (SIMD3(0.01, 0.008, 0), SIMD3(0.002, 0.018, 0)),
            (SIMD3(0.012, 0.004, 0), SIMD3(0.003, 0.02, 0)),
            (SIMD3(0.1, 0, 0), SIMD3(0.1, 0.1, 0)), (SIMD3(0.1, 0, 0), SIMD3(0.1, 0.11, 0)),
            (SIMD3(0.1, 0, 0), SIMD3(0.1, 0.09, 0)),
        ]
        let cosineForm: (SIMD3<Double>, SIMD3<Double>) -> Bool = { a, b in
            simd_dot(a, b) > (simd_dot(a, a) * simd_dot(b, b)).squareRoot() * cos(45 * .pi / 180)
        }
        var cosineFormDiffers = 0
        for (a, b) in pairs {
            let always = simd_dot(a, b) > (simd_dot(a, a) * simd_dot(b, b) * 0.5).squareRoot()
            XCTAssertEqual(rule.pointsSameWay(a, b), always, "\(a) \(b)")
            XCTAssertEqual(rule.pointsSameWay(b, a), always, "\(b) \(a)")
            if cosineForm(a, b) != always { cosineFormDiffers += 1 }
        }
        // The first pair is the one that told the two forms apart: this test would not mean anything if it did not.
        XCTAssertGreaterThan(cosineFormDiffers, 0)
        XCTAssertTrue(rule.pointsSameWay(pairs[0].0, pairs[0].1))
    }

    /// A window of states is judged only when they arrived no further apart than the arrival gap.
    func testTheDirectionalRuleNeedsStatesNoFurtherApartThanItsArrivalGap() {
        for (name, blocked, lowest) in TestResponse.all {
            for (extraMs, expectBlocked) in [(0, true), (1, false)] {
                let gap = blocked.arrivalGapMs + extraMs
                var monitor = monitor(blocked, lowest, box: wholeRoom)
                let times = stride(from: gap, through: gap * (blocked.windowMs / gap + 4), by: gap).map { t in
                    Step(atMs: t, arm: onTable, command: onTable + SIMD3(0.4, 0, 0))
                }
                XCTAssertEqual(blockedTimes(events(&monitor, times)).count, expectBlocked ? 1 : 0, "\(name) \(gap)")
            }
        }
    }

    // MARK: Lowest, on the tool point

    /// The events of a tool-point hold with the lowest rule on: the arm stands where it is, the command is the arm plus
    /// a lead of `lead(t)` (a lateral part and a part lower), every `stepMs`.
    private func toolRun(
        _ blocked: BlockedRule, _ lowest: LowestRule, through: Int, lead: (Int) -> (sideways: Double, lower: Double)
    ) -> [(atMs: Int, event: FeedbackEvent)] {
        var monitor = monitor(blocked, lowest, reportsLowest: true)
        var heard: [(atMs: Int, event: FeedbackEvent)] = []
        for t in stride(from: stepMs, through: through, by: stepMs) {
            let ask = lead(t)
            monitor.commanded(onTable + SIMD3(ask.sideways, 0, -ask.lower), point: .tool)
            let state = ServerState(
                activity: .poseTracking, endEffector: onTable + SIMD3(0, 0, 0.05), toolPoint: onTable)
            heard += monitor.observe(state, at: t).map { (t, $0) }
        }
        return heard
    }

    /// An ask between the sustain distance and the blocked rule's short distance lower, with a long lateral part, so
    /// that it is a lead the blocked rule judges and the lowest rule does not: 20 % over the sustain distance.
    private func between(_ blocked: BlockedRule, _ lowest: LowestRule) -> Double {
        let ask = lowest.sustainM * 1.2
        XCTAssertLessThan(ask, blocked.shortM)
        return ask
    }

    /// A blocked cue told for an ask of at least the sustain distance lower is the lowest cue's told height: a deeper
    /// ask the same way afterwards is not told as "Can't go lower." again.
    func testABlockedToldForAnAskOfTheSustainDistanceLowerIsTheLowestCuesToldHeight() {
        for (name, blocked, lowest) in TestResponse.all {
            let ask = between(blocked, lowest)
            let heard = toolRun(blocked, lowest, through: 3 * blocked.windowMs) { t in
                t <= 2 * blocked.windowMs ? (0.1, ask) : (0.1, blocked.shortM * 1.25)
            }
            XCTAssertEqual(
                heard.map(\.atMs), [blocked.windowMs + stepMs], "\(name): one cue, when the first window is full")
            XCTAssertEqual(heard.map(\.event), [.limit(.blocked)], name)
        }
    }

    /// A tool-point ask the lowest rule can judge (every state of the second at least the sustain distance lower, and one
    /// of them far enough to count as asking lower) is left to it, not told as blocked: a state of the second that asked
    /// the least, past the short distance once, is judged the moment that state is a second old.
    func testAWindowOfAsksAllReachingTheSustainDistanceIsLeftToTheLowestRule() {
        for (name, blocked, lowest) in TestResponse.all {
            let ask = between(blocked, lowest)
            let heard = toolRun(blocked, lowest, through: 3 * blocked.windowMs) { t in
                (0.1, t == stepMs ? blocked.shortM * 1.25 : ask)
            }
            XCTAssertEqual(heard.map(\.atMs), [blocked.windowMs + 2 * stepMs], "\(name): after the deep state is old")
            XCTAssertEqual(heard.map(\.event), [.limit(.blocked)], name)
        }
    }

    /// Back at the lowest height found, a window of the quick length whose asks all reach the quick distance is left to
    /// the lowest rule although the second before it did not ask that much; one that does not reach it is judged by the
    /// blocked rule as soon as the second is full.
    func testAQuickWindowOfAsksIsLeftToTheLowestRuleOnlyWhenItReachesTheQuickDistance() {
        for (name, blocked, lowest) in TestResponse.all {
            let ask = between(blocked, lowest)
            var monitor = monitor(blocked, lowest, reportsLowest: true)
            // The first press finds the lowest height by the full stall.
            var first: [FeedbackEvent] = []
            for t in stride(from: stepMs, through: blocked.windowMs + stepMs, by: stepMs) {
                monitor.commanded(onTable + SIMD3(0.1, 0, -blocked.shortM * 1.25), point: .tool)
                first += monitor.observe(
                    ServerState(
                        activity: .poseTracking, endEffector: onTable + SIMD3(0, 0, 0.05), toolPoint: onTable),
                    at: t)
            }
            XCTAssertEqual(first, [.limit(.lowest)], name)
            monitor.released(.pose)
            let pressedAt = blocked.windowMs + 2 * stepMs
            monitor.startSent(.pose, restart: false, at: pressedAt)
            // One deep state, two that ask nothing, then states of the in-between ask until the second is full.
            let last = blocked.windowMs / stepMs + 1
            XCTAssertGreaterThanOrEqual(Double(last - 3) * Double(stepMs), Double(lowest.quickMs) + Double(stepMs))
            var heard: [(step: Int, event: FeedbackEvent)] = []
            for i in 1...(last + 3) {
                let lower = i == 1 ? blocked.shortM * 1.25 : (i <= 3 ? 0 : ask)
                monitor.commanded(onTable + SIMD3(0.1, 0, -lower), point: .tool)
                heard += monitor.observe(
                    ServerState(
                        activity: .poseTracking, endEffector: onTable + SIMD3(0, 0, 0.05), toolPoint: onTable),
                    at: pressedAt + i * stepMs
                ).map { (i, $0) }
            }
            if ask >= lowest.quickShortM {
                // The quick window reaches the quick distance: the lowest rule judges it, and tells it as a quick stall.
                XCTAssertEqual(heard.map(\.event), [.limit(.lowest)], name)
            } else {
                // It does not: the blocked rule judges it as soon as the second is full.
                XCTAssertEqual(heard.map(\.step), [last], name)
                XCTAssertEqual(heard.map(\.event), [.limit(.blocked)], name)
            }
        }
    }

    // MARK: Lowest

    private func lowestRun(
        _ blocked: BlockedRule, _ lowest: LowestRule, through: Int, arm: (Int) -> SIMD3<Double>,
        depth: (Int) -> Double
    ) -> [Int] {
        var monitor = monitor(blocked, lowest, reportsLowest: true)
        let run = steps(through: through, arm: arm, command: { t, arm in arm + SIMD3(0, 0, -depth(t)) })
        return lowestTimes(events(&monitor, run))
    }

    /// The full stall: the newest state asked at least the blocked rule's short distance lower, every state of the
    /// window at least the lowest rule's sustain distance lower.
    func testTheFullLowestStallNeedsEveryStateOfTheWindowToAskItsSustainDistance() {
        for (name, blocked, lowest) in TestResponse.all {
            XCTAssertLessThan(lowest.sustainM * 1.1, blocked.shortM, "\(name): the sustain is the lesser ask")
            let last = blocked.windowMs + stepMs
            for (share, expectTold) in [(0.9, false), (1.1, true)] {
                let times = lowestRun(
                    blocked, lowest, through: last, arm: { _ in onTable },
                    depth: { $0 == last ? blocked.shortM * 1.1 : lowest.sustainM * share })
                XCTAssertEqual(times, expectTold ? [last] : [], "\(name) \(share)")
            }
        }
    }

    /// An arm still coming down at the descent rate or faster is not at its lowest yet; a slower one is.
    func testTheLowestRuleSaysNothingWhileTheArmStillComesDownAtItsDescentRate() {
        for (name, blocked, lowest) in TestResponse.all {
            for (share, expectTold) in [(0.7, true), (1.3, false)] {
                let perMs = lowest.descentMps * share / 1000
                let times = lowestRun(
                    blocked, lowest, through: 2 * blocked.windowMs + stepMs,
                    arm: { onTable + SIMD3(0, 0, -perMs * Double($0)) }, depth: { _ in 2 * blocked.shortM })
                XCTAssertEqual(!times.isEmpty, expectTold, "\(name) \(share)")
            }
        }
    }

    /// A second visit to the lowest height found is told sooner: an arm within the blocked rule's moved distance of it,
    /// asked at least the quick distance lower, and moving less than the quick moved distance over the quick window.
    private func secondVisit(
        _ blocked: BlockedRule, _ lowest: LowestRule, height: Double, wobble: Double, depth: Double
    ) -> (arrivedAt: Int, told: [Int]) {
        var monitor = monitor(blocked, lowest, reportsLowest: true)
        // The first press finds the lowest height by the full stall.
        let first = steps(
            through: blocked.windowMs + stepMs, arm: { _ in onTable },
            command: { _, arm in arm + SIMD3(0, 0, -2 * blocked.shortM) })
        XCTAssertEqual(lowestTimes(events(&monitor, first)).count, 1)
        monitor.released(.pose)
        let pressedAt = blocked.windowMs + 2 * stepMs
        monitor.startSent(.pose, restart: false, at: pressedAt)
        let visit = (1...(3 * blocked.windowMs / stepMs)).map { i -> Step in
            let arm = onTable + SIMD3(0, 0, height + (i % 2 == 0 ? wobble : 0))
            return Step(atMs: pressedAt + i * stepMs, arm: arm, command: arm + SIMD3(0, 0, -depth))
        }
        return (pressedAt + stepMs, lowestTimes(events(&monitor, visit)))
    }

    func testTheQuickerStallNeedsItsQuickDistanceLower() {
        for (name, blocked, lowest) in TestResponse.all {
            XCTAssertLessThan(lowest.quickShortM * 1.1, blocked.shortM, "\(name): under the full stall's ask")
            let below = secondVisit(blocked, lowest, height: 0, wobble: 0, depth: lowest.quickShortM * 0.9)
            XCTAssertEqual(below.told, [], "\(name): 90 % of the quick distance")
            let enough = secondVisit(blocked, lowest, height: 0, wobble: 0, depth: lowest.quickShortM * 1.1)
            XCTAssertEqual(enough.told.count, 1, "\(name): 110 % of it")
        }
    }

    func testTheQuickerStallNeedsLessThanItsQuickMovedDistanceOfMotion() {
        for (name, blocked, lowest) in TestResponse.all {
            let depth = lowest.quickShortM * 1.1
            let still = secondVisit(blocked, lowest, height: 0, wobble: lowest.quickMovedM * 0.9, depth: depth)
            XCTAssertEqual(still.told.count, 1, "\(name): 90 % of the quick moved distance")
            let moving = secondVisit(blocked, lowest, height: 0, wobble: lowest.quickMovedM * 1.1, depth: depth)
            XCTAssertEqual(moving.told, [], "\(name): 110 % of it")
        }
    }

    func testTheQuickerStallNeedsTheArmWithinTheBlockedMovedDistanceOfTheLowestHeight() {
        for (name, blocked, lowest) in TestResponse.all {
            let depth = lowest.quickShortM * 1.1
            let near = secondVisit(blocked, lowest, height: blocked.movedM * 0.9, wobble: 0, depth: depth)
            XCTAssertEqual(near.told.count, 1, "\(name): 90 % of the moved distance above it")
            let far = secondVisit(blocked, lowest, height: blocked.movedM * 1.1, wobble: 0, depth: depth)
            XCTAssertEqual(far.told, [], "\(name): 110 % of it")
        }
    }

    func testTheQuickerStallIsToldOnceItsQuickWindowHasPassed() throws {
        for (name, blocked, lowest) in TestResponse.all {
            let visit = secondVisit(blocked, lowest, height: 0, wobble: 0, depth: lowest.quickShortM * 1.1)
            let told = try XCTUnwrap(visit.told.first, name)
            XCTAssertGreaterThanOrEqual(told - visit.arrivedAt, lowest.quickMs, "\(name): not before the window")
            XCTAssertLessThanOrEqual(told - visit.arrivedAt, lowest.quickMs + stepMs, "\(name): and then at once")
        }
    }
}
