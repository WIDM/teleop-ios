import simd
import TeleopCore
import TeleopServerHost
import TeleopServerModel
import XCTest
@testable import Teleop

/// The app over a real socket, against the server model on 127.0.0.1 (`LocalTeleopServer`, a port the system
/// picks). These are the checks that used to need teleop-app's stub server on port 8765.
final class LocalServerTests: XCTestCase {
    private var server: LocalTeleopServer!
    private var position = SIMD3<Float>.zero

    override func setUpWithError() throws {
        server = LocalTeleopServer()
        try server.start()
    }

    override func tearDown() {
        server.stop()
        server = nil
    }

    private func makeModel(address: String) -> AppModel {
        let model = AppModel(
            start: .s1,
            haptics: NoHaptics(),
            pose: { [unowned self] in
                return TestPose.portrait(at: position)
            },
            liveLink: true
        )
        model.session.state.serverAddress = address
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

    func testConnectHoldStopAndRelease() {
        let model = makeModel(address: server.address)
        model.connect()
        XCTAssertTrue(wait(3, until: { model.session.state.connected || model.session.state.serverInputError }))
        XCTAssertTrue(model.session.state.connected)
        XCTAssertEqual(model.session.route, .p5)

        // The probe goes out twice a second; a local round trip is a few milliseconds.
        XCTAssertTrue(wait(3, until: { model.session.state.latencyMs < 80 }), "no latency measured")

        let armBefore = server.inspect { $0.world.arm }
        model.send(.holdArmStart)
        XCTAssertTrue(model.session.state.armMoving)
        // Move 2 cm forward over about 0.6 s, well under the speed limit.
        for step in 1...20 {
            position = SIMD3(0, 0, -0.001 * Float(step))
            _ = wait(0.03, until: { false })
        }
        _ = wait(0.5, until: { false })
        model.send(.holdArmEnd)
        XCTAssertFalse(model.session.state.armMoving)
        _ = wait(0.4, until: { false })
        XCTAssertFalse(model.debugLog.contains { $0.contains("rejected") }, "\(model.debugLog)")
        // Forward is the robot's −Y.
        XCTAssertEqual(server.inspect { $0.world.arm.y } - armBefore.y, -0.02, accuracy: 0.003)

        model.send(.stop)
        XCTAssertEqual(model.session.route, .s4)
        _ = wait(0.5, until: { false })
        XCTAssertEqual(server.inspect { $0.state["estop"] }, true, "STOP reached the server")
        model.send(.releaseStop)
        _ = wait(1.0, until: { false })
        XCTAssertFalse(model.session.state.emergencyStop, "the server's E-stop came back after release")
        XCTAssertEqual(server.inspect { $0.state["estop"] }, false)
        XCTAssertTrue(model.session.state.connected)

        model.send(.switchMode)
        XCTAssertFalse(model.link.isOpen)
    }

    func testNothingListeningFailsOnTheConnectScreen() {
        // The port the system gave the server a moment ago: nothing listens there once it has stopped.
        let address = server.address
        server.stop()
        let model = makeModel(address: address)
        model.connect()
        XCTAssertTrue(wait(7, until: { model.session.state.serverInputError }))
        XCTAssertFalse(model.session.state.connected)
        XCTAssertEqual(model.session.route, .s1)
    }
}
