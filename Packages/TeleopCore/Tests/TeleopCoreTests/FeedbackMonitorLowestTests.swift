import XCTest
@testable import TeleopCore

/// The lowest rule, the guide's aid for an arm that cannot go lower: the blocked rule's stall against a command mostly
/// below is "lowest" in place of "blocked", also after a clamp, once per approach, sooner on a second visit to the
/// lowest height found, and that height is kept until the next welcome. Off, which is the default, every event is
/// version 1.0.1's.
final class FeedbackMonitorLowestTests: XCTestCase {
    private var monitor = FeedbackMonitor(limits: GripperLimits(openDeg: 97, emptyDeg: 2))
    /// Where the jaws stop on the table from the reset pose, gripper link, robot base frame.
    private let onTable = SIMD3(0.02, -0.14, 0.133)

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
        XCTAssertGreaterThanOrEqual(events.first?.atMs ?? 0, 1200, "after the blocked rule's full second")
        XCTAssertEqual(monitor.lowestSeen, onTable.z)
    }

    /// Level, or mostly sideways with a little below: the blocked rule as before, and no lowest height.
    func testAStallWithTheCommandLevelOrMostlySidewaysIsBlocked() {
        for gap in [SIMD3(0.02, 0, 0), SIMD3(0, -0.03, 0), SIMD3(0.03, 0, -0.015), SIMD3(0.012, -0.012, -0.0119)] {
            setUp()
            monitor.startSent(.pose, restart: false, at: 0)
            let events = stand(at: onTable, commanded: gap, from: 200, through: 1600)
            XCTAssertEqual(events.map(\.event), [.limit(.blocked)], "\(gap)")
            XCTAssertNil(monitor.lowestSeen, "\(gap)")
        }
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
                // The wobble is up and down every state, never 2 mm: it is under the blocked rule's motion.
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
}
