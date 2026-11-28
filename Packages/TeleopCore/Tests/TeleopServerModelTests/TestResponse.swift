import TeleopCore

// The feedback monitor's blocked and lowest numbers are the robot profile's. These tests judge the server model's SO-101
// in the S4 simulator, so they run with its numbers (those of `so101-s4-sim.json`), named here once.
extension FeedbackMonitor {
    init(limits: GripperLimits, frames: Frames) {
        self.init(
            limits: limits, frames: frames,
            blocked: BlockedRule(
                shortM: 0.010, movedM: 0.002, windowMs: 1000, freshMs: 400, arrivalGapMs: 400,
                leadProgressShare: 0.10, exclusionM: 0.04, followingShare: 0.5, sameWayDeg: 45),
            lowest: LowestRule(
                sustainM: 0.005, quickShortM: 0.005, quickMovedM: 0.001, quickMs: 300, descentMps: 0.0005))
    }
}
