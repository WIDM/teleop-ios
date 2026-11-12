import XCTest
@testable import TeleopCore

final class FeedbackMonitorTests: XCTestCase {
    private var monitor = FeedbackMonitor(limits: GripperLimits(openDeg: 97, emptyDeg: 2))

    override func setUp() {
        monitor = FeedbackMonitor(limits: GripperLimits(openDeg: 97, emptyDeg: 2))
    }

    private func state(
        _ activity: ServerActivity? = nil, arm: SIMD3<Double>? = nil, jaw: Double? = nil, episode: Int? = nil
    ) -> ServerState {
        ServerState(activity: activity, endEffector: arm, episode: episode, gripperDeg: jaw)
    }

    // MARK: Acceptance (I-4)

    func testGoComesOnlyAfterTheAcceptanceTimeWithNoRefusal() {
        monitor.startSent(.pose, restart: false, at: 1000)
        XCTAssertEqual(monitor.tick(at: 1299), [])
        XCTAssertEqual(monitor.tick(at: 1300), [.holdLive(hold: 1)], "300 ms with no round trip measured")
        XCTAssertEqual(monitor.tick(at: 1400), [], "once")
    }

    func testTheAcceptanceTimeFollowsTheMedianRoundTrip() {
        for ms in [20, 30, 25, 400, 22] { monitor.roundTrip(ms: ms) }
        XCTAssertEqual(monitor.acceptanceMs, 100, "25 + 50 is under the 100 ms floor")
        for _ in 0..<10 { monitor.roundTrip(ms: 180) }
        XCTAssertEqual(monitor.acceptanceMs, 230)
        for _ in 0..<10 { monitor.roundTrip(ms: 900) }
        XCTAssertEqual(monitor.acceptanceMs, 300)
    }

    func testARefusalWithinTheAcceptanceTimeIsANoWithItsReason() {
        let cases: [String: Refusal] = [
            "busy": .busy, "sim_not_ready": .notReady, "estop_active": .emergencyStop,
            "invalid_rate_hz": .serverRefused,
        ]
        for (reason, refusal) in cases {
            monitor.startSent(.wrist, restart: false, at: 0)
            XCTAssertEqual(monitor.startRefused(reason: reason, at: 20), [.refused(refusal)], reason)
            XCTAssertEqual(monitor.tick(at: 1000), [], "no GO after a refusal")
        }
    }

    func testARefusalAfterGoEndsTheHoldWithLetGo() {
        monitor.startSent(.pose, restart: false, at: 0)
        _ = monitor.tick(at: 300)
        XCTAssertEqual(monitor.startRefused(reason: "busy", at: 400), [.letGo(.lateRejection)])
        monitor.startSent(.gripper(.closed), restart: false, at: 1000)
        _ = monitor.tick(at: 1300)
        XCTAssertEqual(monitor.startRefused(reason: "gripper_jog_watchdog_timeout", at: 2000), [.letGo(.watchdog)])
    }

    func testAnEmergencyStopEndingTheHoldIsNeitherNoNorLetGo() {
        monitor.startSent(.pose, restart: false, at: 0)
        _ = monitor.tick(at: 300)
        XCTAssertEqual(monitor.startRefused(reason: "pose_tracking_safety_stop", at: 900), [])
        XCTAssertNil(monitor.engagedHold)
    }

    /// §5.4: a hold ended by success plays no LETGO.
    func testAHoldTheServerEndsWithASuccessEndsWithoutACue() {
        monitor.startSent(.pose, restart: false, at: 0)
        _ = monitor.tick(at: 300)
        XCTAssertEqual(monitor.startRefused(reason: "task_success", at: 2000), [])
        XCTAssertNil(monitor.engagedHold)
        monitor.startSent(.gripper(.open), restart: false, at: 3000)
        XCTAssertEqual(monitor.startRefused(reason: "task_success", at: 3050), [], "nor a NO before GO")
    }

    /// The success display holds the arm still while the phone may keep moving; that is not "Blocked.".
    func testNothingIsJudgedWhileTheSuccessShows() {
        monitor.startSent(.pose, restart: false, at: 0)
        _ = monitor.tick(at: 300)
        let arm = SIMD3<Double>(0, -0.14, 0.16)
        monitor.commanded(arm + SIMD3(0, 0, 0.03))
        var events: [FeedbackEvent] = []
        for t in stride(from: 400, through: 2400, by: 200) {
            events += monitor.observe(
                ServerState(activity: .taskSuccess, endEffector: arm, taskSuccess: true, episode: 1), at: t)
        }
        XCTAssertEqual(events, [])
    }

    func testAHoldTheAppEndsIsALetGoWithItsReason() {
        monitor.startSent(.pose, restart: false, at: 0)
        XCTAssertEqual(monitor.endedByApp(.tooFast), [.letGo(.tooFast)])
        XCTAssertEqual(monitor.endedByApp(.tooFast), [], "nothing engaged any more")
    }

    func testAReleasedHoldGetsNoGo() {
        monitor.startSent(.pose, restart: false, at: 0)
        monitor.released()
        XCTAssertEqual(monitor.tick(at: 500), [])
    }

    func testARestartKeepsTheHoldAndItsGo() {
        monitor.startSent(.pose, restart: false, at: 0)
        XCTAssertEqual(monitor.tick(at: 300), [.holdLive(hold: 1)])
        monitor.startSent(.pose, restart: true, at: 1500)
        XCTAssertEqual(monitor.engagedHold, 1)
        XCTAssertEqual(monitor.tick(at: 1900), [], "no second GO")
        monitor.released()
        monitor.startSent(.pose, restart: false, at: 3000)
        XCTAssertEqual(monitor.engagedHold, 2)
    }

    // MARK: Limits

    func testAWorkspaceClampCountsOnlyAfterTheHoldsOwnLabel() {
        monitor.startSent(.pose, restart: false, at: 0)
        XCTAssertEqual(monitor.observe(state(.poseClamped), at: 50), [], "left over from the hold before")
        XCTAssertEqual(monitor.observe(state(.poseTracking), at: 250), [])
        XCTAssertEqual(monitor.observe(state(.poseClamped), at: 450), [.limit(.workspace)])
        XCTAssertEqual(monitor.observe(state(.poseClamped), at: 650), [], "once per hold")
    }

    func testAWristClampCountsAfterOrienting() {
        monitor.startSent(.wrist, restart: false, at: 0)
        XCTAssertEqual(monitor.observe(state(.orientClamped), at: 50), [])
        _ = monitor.observe(state(.orienting), at: 250)
        XCTAssertEqual(monitor.observe(state(.orientClamped), at: 450), [.limit(.wrist)])
    }

    func testFullyOpen() {
        monitor.startSent(.gripper(.open), restart: false, at: 0)
        XCTAssertEqual(monitor.observe(state(jaw: 60), at: 200), [])
        XCTAssertEqual(monitor.observe(state(jaw: 97.5), at: 400), [.limit(.fullyOpen)])
        XCTAssertEqual(monitor.observe(state(jaw: 99), at: 600), [])
    }

    func testContactWhileClosingGripsAndSetsGripping() {
        monitor.startSent(.gripper(.closed), restart: false, at: 0)
        XCTAssertEqual(monitor.observe(state(.gripperJogging, jaw: 40), at: 200), [])
        XCTAssertEqual(monitor.observe(state(.gripperContact, jaw: 8), at: 400), [.contact])
        XCTAssertEqual(monitor.observe(state(.gripperContact, jaw: 8), at: 600), [], "once per close")
        monitor.released()
        XCTAssertTrue(monitor.gripping)
    }

    /// §5.7: contact that shows only in the states after letting go of a close (the jaws met the cube in the last
    /// moment, or the listening connection is down and the first state comes after the stop) still grips.
    func testContactSeenJustAfterLettingGoOfACloseStillGrips() {
        monitor.startSent(.gripper(.closed), restart: false, at: 0)
        _ = monitor.tick(at: 300)
        XCTAssertEqual(monitor.observe(state(.gripperJogging, jaw: 30), at: 400), [])
        monitor.released(.gripper(.closed))
        XCTAssertEqual(monitor.observe(state(.gripperJogging, jaw: 22), at: 480), [], "the server has not stopped yet")
        XCTAssertEqual(monitor.observe(state(.gripperContact, jaw: 18), at: 560), [.contact])
        XCTAssertTrue(monitor.gripping)
        XCTAssertEqual(monitor.observe(state(.gripperContact, jaw: 18), at: 760), [], "once")
    }

    func testOnlyTheStatesRightAfterACloseCanStillGrip() {
        monitor.startSent(.gripper(.closed), restart: false, at: 0)
        monitor.released(.gripper(.closed))
        XCTAssertEqual(monitor.observe(state(.ok, jaw: 30), at: 200), [], "the server stopped the jaws first")
        XCTAssertEqual(monitor.observe(state(.gripperContact, jaw: 18), at: 400), [])
        XCTAssertFalse(monitor.gripping)
        monitor.startSent(.gripper(.open), restart: false, at: 600)
        monitor.released(.gripper(.open))
        XCTAssertEqual(monitor.observe(state(.gripperContact), at: 800), [], "after an open")
        monitor.startSent(.gripper(.closed), restart: false, at: 1000)
        monitor.released()
        XCTAssertEqual(monitor.observe(state(.gripperContact), at: 1200), [], "after an emergency stop")
        XCTAssertFalse(monitor.gripping)
    }

    func testAResetOrANewWelcomeForgetsACloseJustLetGoOf() {
        monitor.startSent(.gripper(.closed), restart: false, at: 0)
        monitor.released(.gripper(.closed))
        monitor.sceneReset()
        XCTAssertEqual(monitor.observe(state(.gripperContact, jaw: 18), at: 200), [], "after a scene reset")
        XCTAssertFalse(monitor.gripping)

        monitor.startSent(.gripper(.closed), restart: false, at: 400)
        monitor.released(.gripper(.closed))
        monitor.welcomed(session: "a")
        XCTAssertEqual(monitor.observe(state(.gripperContact, jaw: 18), at: 600), [], "after a new welcome")
        XCTAssertFalse(monitor.gripping)
    }

    func testAnEmptyClose() {
        monitor.startSent(.gripper(.closed), restart: false, at: 0)
        XCTAssertEqual(monitor.observe(state(.gripperJogging, jaw: 30), at: 200), [])
        XCTAssertEqual(monitor.observe(state(.gripperJogging, jaw: 1.5), at: 400), [.limit(.empty)])
        XCTAssertEqual(monitor.observe(state(.gripperJogging, jaw: -10), at: 600), [])
        XCTAssertFalse(monitor.gripping)
    }

    func testGrippingEndsWithAnOpenAResetOrANewServerRun() {
        func grip() {
            monitor.startSent(.gripper(.closed), restart: false, at: 0)
            _ = monitor.observe(state(.gripperContact, jaw: 8, episode: 1), at: 100)
            monitor.released()
            XCTAssertTrue(monitor.gripping)
        }
        monitor.welcomed(session: "a")
        grip()
        monitor.startSent(.gripper(.open), restart: false, at: 200)
        XCTAssertFalse(monitor.gripping, "an open")
        monitor.released()
        grip()
        _ = monitor.observe(state(episode: 2), at: 300)
        XCTAssertFalse(monitor.gripping, "a new episode")
        grip()
        monitor.welcomed(session: "a")
        XCTAssertTrue(monitor.gripping, "a reconnect to the same server run")
        monitor.welcomed(session: "b")
        XCTAssertFalse(monitor.gripping, "a new server run")
        grip()
        monitor.sceneReset()
        XCTAssertFalse(monitor.gripping)
    }

    // MARK: Blocked

    func testAStationaryArmFarShortIsBlocked() {
        let arm = SIMD3(0.02, -0.14, 0.133)
        monitor.startSent(.pose, restart: false, at: 0)
        monitor.commanded(arm + SIMD3(0, 0, -0.02))
        var events: [FeedbackEvent] = []
        for t in stride(from: 200, through: 1400, by: 200) {
            events += monitor.observe(state(.poseTracking, arm: arm + SIMD3(0.0003, 0, 0)), at: t)
        }
        XCTAssertEqual(events, [.limit(.blocked)])
    }

    /// Arm at `arm` from 0 to 1.5 s, states every 100 ms, commanded point `short` metres ahead of it.
    private func blockedEvents(
        short: Double, crawlMetresPerSecond: Double = 0, stillFromMs: Int = 0, until end: Int = 1500
    ) -> [Int] {
        monitor = FeedbackMonitor(limits: GripperLimits(openDeg: 97, emptyDeg: 2))
        let start = SIMD3(0.02, -0.14, 0.133)
        monitor.startSent(.pose, restart: false, at: 0)
        var raised: [Int] = []
        for t in stride(from: 100, through: end, by: 100) {
            // Before `stillFromMs` the arm moves 5 mm every state; after it, it crawls.
            let moving = Double(min(t, stillFromMs)) / 100 * 0.005
            let crawl = Double(max(0, t - stillFromMs)) / 1000 * crawlMetresPerSecond
            let arm = start + SIMD3(0, 0, -(moving + crawl))
            monitor.commanded(arm + SIMD3(0, 0, -short))
            if monitor.observe(state(.poseTracking, arm: arm), at: t).contains(.limit(.blocked)) { raised.append(t) }
        }
        return raised
    }

    /// The three numbers of the blocked rule, each just inside and just outside: at least 10 mm short, moved less
    /// than 2 mm, over 1.0 s.
    func testTheBlockedRuleNeedsTenMillimetresShort() {
        XCTAssertEqual(blockedEvents(short: 0.009), [])
        XCTAssertEqual(blockedEvents(short: 0.011).count, 1)
    }

    func testTheBlockedRuleNeedsLessThanTwoMillimetresOfMotionInASecond() {
        XCTAssertEqual(blockedEvents(short: 0.03, crawlMetresPerSecond: 0.0015, until: 2500).count, 1)
        XCTAssertEqual(blockedEvents(short: 0.03, crawlMetresPerSecond: 0.0025, until: 2500), [])
    }

    func testTheBlockedRuleNeedsAFullSecondStill() {
        let raised = blockedEvents(short: 0.03, stillFromMs: 1000, until: 2500)
        XCTAssertEqual(raised.count, 1)
        XCTAssertGreaterThan(raised.first ?? 0, 1900, "only 0.9 s still")
        XCTAssertLessThanOrEqual(raised.first ?? .max, 2100, "1.1 s still")
    }

    func testAMovingArmOrOneThatHasArrivedIsNotBlocked() {
        monitor.startSent(.pose, restart: false, at: 0)
        var events: [FeedbackEvent] = []
        // 2 cm/s toward a point 3 cm away: slow, but moving.
        for (index, t) in stride(from: 200, through: 1600, by: 200).enumerated() {
            monitor.commanded(SIMD3(0, 0, 0.03))
            events += monitor.observe(state(.poseTracking, arm: SIMD3(0, 0, 0.004 * Double(index))), at: t)
        }
        // Arrived within a few millimetres and standing still.
        for t in stride(from: 1800, through: 3600, by: 200) {
            monitor.commanded(SIMD3(0, 0, 0.03))
            events += monitor.observe(state(.poseTracking, arm: SIMD3(0, 0, 0.025)), at: t)
        }
        XCTAssertEqual(events, [])
    }

    func testStaleMeasurementsNeverReadAsBlocked() {
        monitor.startSent(.pose, restart: false, at: 0)
        monitor.commanded(SIMD3(0, 0, 0.05))
        _ = monitor.observe(state(.poseTracking, arm: .zero), at: 100)
        XCTAssertEqual(monitor.observe(state(.poseTracking, arm: nil), at: 1500), [], "no position since 1.4 s")
    }

    func testAClampedHoldIsAtItsLimitNotBlocked() {
        monitor.startSent(.pose, restart: false, at: 0)
        monitor.commanded(SIMD3(0.1, 0, 0))
        var events: [FeedbackEvent] = []
        events += monitor.observe(state(.poseTracking, arm: .zero), at: 100)
        for t in stride(from: 300, through: 1500, by: 200) {
            events += monitor.observe(state(.poseClamped, arm: SIMD3(0.08, 0, 0)), at: t)
        }
        XCTAssertEqual(events, [.limit(.workspace)])
    }
}
