import simd

@testable import TeleopCore

/// The motion and the server facts the rule tests run with. A test names one here, never a literal of its own.
enum TestMotion {
    /// The SO-101 in the S4 simulator, the numbers of `so101-s4-sim.json`.
    static let so101 = MotionProfile(fineMps: 0.01, coarseMps: 0.04, maxLeadM: 0.08, toolMaxLeadM: 0.005)

    /// Bench arm B: buttons twice as fast, and the lead cap lowered so that it stays under B's 6 cm stop distance.
    static let benchB = MotionProfile(fineMps: 0.02, coarseMps: 0.08, maxLeadM: 0.05, toolMaxLeadM: 0.005)

    static let all: [(name: String, motion: MotionProfile)] = [("SO-101", so101), ("bench arm B", benchB)]
}

/// The server facts the rule tests run with.
enum TestServer {
    /// The S4 server: stops the arm at 10 cm, resyncs a hold after 1.5 s (0.5 s on the tool point), and lifts a held
    /// object through the gripper link.
    static let so101 = ServerProfile(
        stopDistanceM: 0.10, resync: ResyncTimes(afterMs: 1500, toolAfterMs: 500, timeoutMs: 1500),
        heldObjectPoint: .gripperLink, stallDetection: .simulation)

    /// Bench arm B's server: stops the arm at 6 cm, resyncs sooner and has no simulation loop to watch.
    static let benchB = ServerProfile(
        stopDistanceM: 0.06, resync: ResyncTimes(afterMs: 1200, toolAfterMs: 400, timeoutMs: 1000),
        heldObjectPoint: .gripperLink, stallDetection: .none)

    static let all: [(name: String, server: ServerProfile)] = [("SO-101", so101), ("bench arm B", benchB)]
}

// What the rule tests built before the speeds came from the profile: the SO-101's, named here once so that a test that
// is not about the motion reads as it did.
extension ButtonSpeed {
    var metresPerSecond: Double { metresPerSecond(in: TestMotion.so101) }
}

extension ButtonRamp {
    init(direction: OperatorDirection, speed: ButtonSpeed, startMs: Int, frames: Frames) {
        self.init(direction: direction, speed: speed, startMs: startMs, frames: frames, motion: TestMotion.so101)
    }
}

extension ButtonArbiter {
    init(frames: Frames, speed: ButtonSpeed = .coarse) {
        self.init(frames: frames, motion: TestMotion.so101, speed: speed)
    }
}

extension SimStallDetector {
    /// The S4 server's detector, as the tests that are not about the choice build one.
    init() { self.init(detection: TestServer.so101.stallDetection) }
}

extension ObjectHold {
    init() { self.init(heldObjectPoint: TestServer.so101.heldObjectPoint) }
}

/// The numbers the blocked rule and the lowest rule are judged by.
enum TestResponse {
    /// The SO-101 in the S4 simulator, the numbers of `so101-s4-sim.json`.
    static let so101Blocked = BlockedRule(
        shortM: 0.010, movedM: 0.002, windowMs: 1000, freshMs: 400, arrivalGapMs: 400, leadProgressShare: 0.10,
        exclusionM: 0.04, followingShare: 0.5, sameWayDeg: 45)
    static let so101Lowest = LowestRule(
        sustainM: 0.005, quickShortM: 0.005, quickMovedM: 0.001, quickMs: 300, descentMps: 0.0005)

    /// Bench arm B answers twice as fast: distances twice as long, windows half as long, rates twice as high, and its
    /// own shares and angle, so that a rule that reads one of these from the SO-101 gives a different answer.
    static let benchBBlocked = BlockedRule(
        shortM: 0.020, movedM: 0.004, windowMs: 500, freshMs: 300, arrivalGapMs: 200, leadProgressShare: 0.15,
        exclusionM: 0.06, followingShare: 0.8, sameWayDeg: 30)
    static let benchBLowest = LowestRule(
        sustainM: 0.010, quickShortM: 0.010, quickMovedM: 0.002, quickMs: 150, descentMps: 0.001)

    static let all: [(name: String, blocked: BlockedRule, lowest: LowestRule)] = [
        ("SO-101", so101Blocked, so101Lowest), ("bench arm B", benchBBlocked, benchBLowest),
    ]
}

/// How a going move follows the arm's pace.
enum TestPacing {
    static let so101 = GoToPacing(
        followShare: 0.5, paceGain: 0.25, slowestShare: 0.15, startShare: 0.5, pathWatchTolerances: 2.5, freshMs: 400,
        stillM: 0.002, paceChangeShare: 0.05)

    /// Bench arm B: a laggy arm that is followed less eagerly, paced more gently, watched more closely.
    static let benchB = GoToPacing(
        followShare: 0.4, paceGain: 0.5, slowestShare: 0.25, startShare: 0.3, pathWatchTolerances: 2, freshMs: 300,
        stillM: 0.004, paceChangeShare: 0.1)

    static let all: [(name: String, pacing: GoToPacing)] = [("SO-101", so101), ("bench arm B", benchB)]
}

extension FeedbackMonitor {
    init(limits: GripperLimits, frames: Frames) {
        self.init(
            limits: limits, frames: frames, blocked: TestResponse.so101Blocked, lowest: TestResponse.so101Lowest)
    }
}

extension GoToLimits {
    /// The SO-101's pacing, as the tests that are not about it build their limits.
    init(
        travelHeightM: Double, speedMps: Double, arriveToleranceM: Double, corrections: Int, correctionReachM: Double,
        settleS: Double, timeFactor: Double, allowanceS: Double, armDataTimeoutS: Double, startGraceS: Double = 0
    ) {
        self.init(
            travelHeightM: travelHeightM, speedMps: speedMps, arriveToleranceM: arriveToleranceM,
            corrections: corrections, correctionReachM: correctionReachM, settleS: settleS, timeFactor: timeFactor,
            allowanceS: allowanceS, armDataTimeoutS: armDataTimeoutS, startGraceS: startGraceS,
            pacing: TestPacing.so101)
    }
}
