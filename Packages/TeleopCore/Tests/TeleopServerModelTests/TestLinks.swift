@testable import TeleopCore

// The server model reports its jaw in degrees, 0 shut and 97 open: the SO-101's readings, which the links these tests
// build accept.
extension TeleopLink {
    convenience init(send: @escaping (String) -> Void, now: @escaping () -> Int) {
        self.init(send: send, now: now, jawReadings: -360...360)
    }
}

extension ServerState {
    init(payload: [String: Any]) { self.init(payload: payload, jawReadings: -360...360) }
}
