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
        heldObjectPoint: .gripperLink)

    /// Bench arm B's server: stops the arm at 6 cm, and resyncs sooner.
    static let benchB = ServerProfile(
        stopDistanceM: 0.06, resync: ResyncTimes(afterMs: 1200, toolAfterMs: 400, timeoutMs: 1000),
        heldObjectPoint: .gripperLink)

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

extension ObjectHold {
    init() { self.init(heldObjectPoint: TestServer.so101.heldObjectPoint) }
}
