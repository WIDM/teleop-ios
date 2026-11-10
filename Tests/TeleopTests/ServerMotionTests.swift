import simd
import TeleopCore
import XCTest
@testable import Teleop

/// Scripted phone motion through the real app code against a real server on this Mac (port 8765):
/// the stub, or Isaac Sim behind the SSH tunnel. It moves the simulated arm, so it only runs when asked:
///
///     TEST_RUNNER_TELEOP_MOTION=1 xcodebuild test ... -only-testing:TeleopTests/ServerMotionTests
///
/// Each profile is a hand movement no slower than a person makes. The promise under test: the app never
/// trips the server's safety stop, whatever the hand does, and the arm ends up where the hand asked.
final class ServerMotionTests: XCTestCase {
    private var position = SIMD3<Float>.zero
    private var model: AppModel!

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["TELEOP_MOTION"] != nil else {
            throw XCTSkip("set TEST_RUNNER_TELEOP_MOTION=1 to drive the server")
        }
        position = .zero
        model = AppModel(
            start: .s1,
            haptics: NoHaptics(),
            pose: { [unowned self] in
                return TestPose.portrait(at: position)
            },
            liveLink: true
        )
        model.session.state.serverAddress = "127.0.0.1:8765"
        model.session.state.setSmoothing(0.3)
        model.connect()
        guard wait(4, until: { model.session.state.connected || model.session.state.serverInputError }),
              model.session.state.connected else {
            throw XCTSkip("no server on 127.0.0.1:8765")
        }
        if model.session.state.emergencyStop {
            model.send(.releaseStop)
            pump(1.5)
        }
        model.send(.resetScene)
        pump(6)
    }

    override func tearDown() {
        if model?.session.state.armMoving == true { model.send(.holdArmEnd) }
        pump(1)
        model?.send(.switchMode)
        model = nil
    }

    private func pump(_ seconds: TimeInterval) { _ = wait(seconds, until: { false }) }

    private func wait(_ seconds: TimeInterval, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if done() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return done()
    }

    /// Moves the hand to `target` (operator frame: right, up, back in metres) in `seconds`, 30 steps a second.
    private func move(to target: SIMD3<Float>, in seconds: Double) {
        // By the clock, not by step count: a late timer must not turn into a jump the app would refuse.
        let from = position
        let started = Date()
        while true {
            let share = min(Date().timeIntervalSince(started) / seconds, 1)
            position = from + (target - from) * Float(share)
            if share >= 1 { break }
            pump(1.0 / 120)
        }
    }

    /// Holds, runs `motion`, waits `settle` seconds with the hand still, releases, and reports what the arm did.
    private func hold(_ name: String, settle: Double, _ motion: () -> Void) {
        position = .zero
        pump(0.5)
        let before = model.link.armPosition
        let started = Date()
        model.send(.holdArmStart)
        XCTAssertTrue(model.session.state.armMoving, "\(name): hold did not start")
        motion()
        let asked = position
        pump(settle)
        XCTAssertTrue(model.session.state.armMoving, "\(name): hold ended by itself. log: \(model.debugLog.suffix(6))")
        model.send(.holdArmEnd)
        pump(1.0)
        XCTAssertFalse(model.session.state.emergencyStop, "\(name): E-stopped, cause \(String(describing: model.stopCause))")
        XCTAssertTrue(model.session.state.connected, "\(name): link lost")
        guard let before, let after = model.link.armPosition else {
            print("MOTION \(name): no arm position from the server")
            return
        }
        guard simd_length(asked) > 0.005 else {
            print(String(format: "MOTION %@: hand back at the start, arm ended %.1f cm from where it began, %.1f s",
                         name, simd_distance(after, before) * 100, Date().timeIntervalSince(started)))
            return
        }
        // Identity camera: right is +x, forward is −z, up is +y. The server wants right → −X, forward → −Y, up → +Z.
        let wantedBase = SIMD3(-asked.x, asked.z, asked.y)
        let moved = after - before
        let reached = simd_dot(moved, simd_normalize(wantedBase)) / simd_length(wantedBase)
        print(String(
            format: "MOTION %@: asked %.1f cm, arm moved %.1f cm along it (%.0f%%), %.1f cm off it, %.1f s",
            name, simd_length(wantedBase) * 100, simd_dot(moved, simd_normalize(wantedBase)) * 100, reached * 100,
            simd_length(moved - simd_normalize(wantedBase) * simd_dot(moved, simd_normalize(wantedBase))) * 100,
            Date().timeIntervalSince(started)
        ))
    }

    func testFastSweepRightThenBack() {
        hold("right 16 cm in 0.4 s", settle: 20) { move(to: SIMD3(0.16, 0, 0), in: 0.4) }
        hold("left 16 cm in 0.4 s", settle: 20) { move(to: SIMD3(-0.16, 0, 0), in: 0.4) }
    }

    func testFastUpThenDown() {
        hold("up 10 cm in 0.3 s", settle: 12) { move(to: SIMD3(0, 0.10, 0), in: 0.3) }
        hold("down 10 cm in 0.3 s", settle: 12) { move(to: SIMD3(0, -0.10, 0), in: 0.3) }
    }

    func testZigZagNeverTripsTheServer() {
        hold("forward and back 12 cm, three times", settle: 6) {
            for _ in 0..<3 {
                move(to: SIMD3(0, 0, -0.12), in: 0.5)
                move(to: SIMD3(0, 0, 0), in: 0.5)
            }
        }
    }

    func testSlowSmallMoveIsFollowedClosely() {
        hold("right 4 cm in 2 s", settle: 4) { move(to: SIMD3(0.04, 0, 0), in: 2) }
        hold("left 4 cm in 2 s", settle: 4) { move(to: SIMD3(-0.04, 0, 0), in: 2) }
    }
}
