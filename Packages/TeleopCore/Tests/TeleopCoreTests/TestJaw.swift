@testable import TeleopCore

/// The jaws the rule tests run with. A test names one here, never a literal of its own.
enum TestJaw {
    /// The SO-101 in the S4 simulator, the numbers of `so101-s4-sim.json`: a hinged jaw read in degrees, 0 shut and
    /// 97 open, every reading up to a full turn either way accepted.
    static let so101 = GripperProfile(
        unit: .deg, closedReading: 0, openReading: 97, validMin: -360, validMax: 360, fullyOpenAt: 97, emptyAt: 2)

    /// The jaws of bench arm B: parallel, read in millimetres between the pads, 0 shut and 40 open.
    static let benchB = GripperProfile(
        unit: .mm, closedReading: 0, openReading: 40, validMin: 0, validMax: 45, fullyOpenAt: 39, emptyAt: 1)

    static let all: [(name: String, jaw: GripperProfile)] = [("SO-101", so101), ("bench arm B", benchB)]
}

// What the tests built with no jaw in sight before the readings that count came from the profile.
extension ServerState {
    /// A state read with the SO-101's jaw readings.
    init(payload: [String: Any]) { self.init(payload: payload, jawReadings: TestJaw.so101.validReadings) }
}

extension TeleopLink {
    /// A link that accepts the SO-101's jaw readings.
    convenience init(send: @escaping (String) -> Void, now: @escaping () -> Int) {
        self.init(send: send, now: now, jawReadings: TestJaw.so101.validReadings)
    }
}
