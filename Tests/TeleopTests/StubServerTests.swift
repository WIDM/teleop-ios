import simd
import TeleopCore
import XCTest
@testable import Teleop

/// Real socket against teleop-app's stub_server.py on this Mac (`python3 stub_server.py`, port 8765).
/// Skipped when the stub is not running, so CI without it stays green.
final class StubServerTests: XCTestCase {
    private var position = SIMD3<Float>.zero

    private func makeModel() -> AppModel {
        let model = AppModel(
            start: .s1,
            haptics: NoHaptics(),
            pose: { [unowned self] in
                return TestPose.portrait(at: position)
            },
            liveLink: true
        )
        model.session.state.serverAddress = "127.0.0.1:8765"
        return model
    }

    private func wait(_ seconds: TimeInterval, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if done() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return done()
    }

    func testConnectHoldStopAndRelease() throws {
        let model = makeModel()
        model.connect()
        guard wait(3, until: { model.session.state.connected || model.session.state.serverInputError }),
              model.session.state.connected else {
            throw XCTSkip("stub_server.py is not running on 127.0.0.1:8765")
        }
        XCTAssertEqual(model.session.route, .p5)

        // The probe goes out once a second; a local round trip is a few milliseconds.
        XCTAssertTrue(wait(3, until: { model.session.state.latencyMs < 80 }), "no latency measured")

        model.send(.holdArmStart)
        XCTAssertTrue(model.session.state.armMoving)
        // Move 2 cm over about 0.6 s, well under the speed limit.
        for step in 1...20 {
            position = SIMD3(0, 0, -0.001 * Float(step))
            _ = wait(0.03, until: { false })
        }
        model.send(.holdArmEnd)
        XCTAssertFalse(model.session.state.armMoving)
        _ = wait(0.4, until: { false })
        XCTAssertFalse(model.debugLog.contains { $0.contains("rejected") }, "\(model.debugLog)")

        model.send(.stop)
        XCTAssertEqual(model.session.route, .s4)
        _ = wait(0.5, until: { false })
        model.send(.releaseStop)
        _ = wait(1.0, until: { false })
        XCTAssertFalse(model.session.state.emergencyStop, "the server's E-stop came back after release")
        XCTAssertTrue(model.session.state.connected)

        model.send(.switchMode)
        XCTAssertFalse(model.link.isOpen)
    }

    func testNothingListeningFailsOnTheConnectScreen() {
        let model = makeModel()
        model.session.state.serverAddress = "127.0.0.1:8799"
        model.connect()
        XCTAssertTrue(wait(7, until: { model.session.state.serverInputError }))
        XCTAssertFalse(model.session.state.connected)
        XCTAssertEqual(model.session.route, .s1)
    }
}
