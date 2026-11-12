import TeleopCore
import TeleopServerHost
import TeleopServerModel
import XCTest
@testable import Teleop

/// What an operator does besides the task, with raw inputs only, against the server model on a local socket: turn
/// and tilt the wrist by rotating the phone in each scheme, STOP during a hold, a press while stopped, the two ways
/// out of the stop state, and the things that end a hold (Settings, leaving the app).
final class LocalOperatorTests: XCTestCase {
    private var server: LocalTeleopServer!
    private var hand: ScriptedOperator!
    private var model: AppModel { hand.model }

    override func tearDown() {
        hand?.finish()
        hand = nil
        server?.stop()
        server = nil
    }

    private func start(_ mode: ControlMode, recorder: ServerModelConfig.Recorder? = nil) throws {
        server = LocalTeleopServer(config: .s4Simulator(stepsPerSecond: 60, recorder: recorder))
        try server.start()
        hand = ScriptedOperator(address: server.address, mode: mode, smoothing: 0.3, pace: 0.3)
        XCTAssertTrue(hand.connect(within: 4), "could not connect to the local server")
        hand.pump(1)
    }

    private var roll: Double { server.inspect { $0.world.wristRoll } }
    private var flex: Double { server.inspect { $0.world.wristFlex } }
    private var serverStopped: Bool { server.inspect { $0.state["estop"] } == true }

    private func heard(_ key: CueKey) -> Bool { model.cueLog.contains { $0.event == key } }

    // MARK: The wrist by the phone's rotation

    private func turnAndTiltAndBringBack(_ mode: ControlMode) throws {
        try start(mode)
        let roll0 = roll, flex0 = flex
        // The screen's state during the holds: measured angles, since this server reports them.
        var turned = 0.0, tilted = 0.0, estimated = false
        hand.watch = { [unowned self] in
            switch model.operating.state {
            case .turning(let degrees, _, let guess):
                turned = max(turned, degrees)
                estimated = estimated || guess
            case .tilting(let degrees, _, let guess):
                tilted = max(tilted, degrees)
                estimated = estimated || guess
            default: break
            }
        }
        defer { hand.watch = nil }
        hand.wrist(.turn, by: 20, hold: 3)
        XCTAssertEqual(roll, roll0 + 20, accuracy: 1.5, "\(mode): turning the phone 20 degrees turns the wrist")
        XCTAssertEqual(flex, flex0, accuracy: 0.5, "\(mode): a turn does not tilt")
        hand.wrist(.turn, by: -20, hold: 3)
        XCTAssertEqual(roll, roll0, accuracy: 1.5, "\(mode): and back")
        hand.wrist(.tilt, by: 10, hold: 3)
        XCTAssertEqual(flex, flex0 + 10, accuracy: 1.5, "\(mode): tipping the top away 10 degrees tilts the wrist")
        XCTAssertEqual(roll, roll0, accuracy: 1.5, "\(mode): a tilt does not turn")
        hand.wrist(.tilt, by: -10, hold: 3)
        XCTAssertEqual(flex, flex0, accuracy: 1.5, "\(mode): and back")
        XCTAssertFalse(serverStopped)
        XCTAssertFalse(model.session.state.wristMoving, "every wrist hold ended with its input")
        XCTAssertGreaterThan(turned, 10, "\(mode): the screen shows the turn")
        XCTAssertGreaterThan(tilted, 5, "\(mode): the screen shows the tilt")
        XCTAssertFalse(estimated, "\(mode): the server reports wrist angles, so nothing is an estimate")
    }

    func testTurnAndTiltTheWristByRotatingThePhoneSchemeA() throws {
        try turnAndTiltAndBringBack(.screenTurns)
    }

    func testTurnAndTiltTheWristByRotatingThePhoneSchemeB() throws {
        try turnAndTiltAndBringBack(.keyTurns)
    }

    // MARK: The stop state

    /// The bottom band stops the arm during a hold, and a press while stopped is refused.
    func testTheBottomBandStopsTheArmDuringAHold() throws {
        try start(.screenTurns)
        hand.press(.upper)
        XCTAssertTrue(model.session.state.armMoving)
        hand.move(to: SIMD3(0.03, 0, 0), in: 0.3)
        hand.tap(x: hand.bottomBand.x, y: hand.bottomBand.y)
        XCTAssertTrue(model.session.state.emergencyStop)
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertTrue(hand.wait(2, until: { serverStopped }), "STOP did not reach the server")
        let stoppedAt = server.inspect { $0.world.arm }
        hand.move(to: SIMD3(0.06, 0, 0), in: 0.3)
        hand.release(.upper)
        hand.pump(1)
        XCTAssertEqual(server.inspect { $0.world.arm }, stoppedAt, "the arm stays where STOP left it")

        hand.pump(2)
        hand.press(.upper)
        XCTAssertFalse(model.session.state.armMoving, "a press while stopped moves nothing")
        XCTAssertTrue(heard(.refused(.emergencyStop)), "and says why")
        hand.release(.upper)
    }

    /// With a recorder, the stop state's only exit is the top band held 2 s: the server's reset clears the stop and
    /// arms the recorder again.
    func testTheTopBandHoldLeavesTheStopWithTheRecorderOn() throws {
        try start(.screenTurns, recorder: .init())
        hand.tap(x: hand.bottomBand.x, y: hand.bottomBand.y)
        XCTAssertTrue(hand.wait(2, until: { serverStopped }))
        hand.pump(1)
        XCTAssertEqual(model.stopExits.exits, [.resetScene], "with a recorder, release is not offered")
        XCTAssertTrue(model.session.state.emergencyStop)
        model.send(.releaseStop)
        hand.pump(1)
        XCTAssertTrue(model.session.state.emergencyStop, "and refused whatever sends it")
        XCTAssertTrue(serverStopped, "nothing released the server's stop")
        XCTAssertTrue(heard(.refused(.deadInput)))

        let band = hand.topBand
        let touch = hand.touchDown(x: band.x, y: band.y)
        _ = hand.wait(1, until: { false })
        XCTAssertNotNil(model.operating.resetCountdown, "the countdown runs while the band is held")
        XCTAssertTrue(model.session.state.emergencyStop, "nothing happens before 2 s")
        _ = hand.wait(1.3, until: { false })
        hand.touchUp(touch, x: band.x, y: band.y)
        XCTAssertTrue(hand.wait(6, until: { !model.session.state.emergencyStop }), "the reset did not release the stop")
        XCTAssertFalse(serverStopped)
        XCTAssertEqual(server.inspect { $0.episode }, 1, "the scene was reset")
        XCTAssertTrue(hand.wait(2, until: { model.serverState?.recorder?.label == .armed }), "the recorder is armed again")
        XCTAssertNotEqual(model.session.route, .s4)

        hand.press(.upper)
        XCTAssertTrue(model.session.state.armMoving, "the arm works again")
        hand.release(.upper)
    }

    /// With no recorder, "Release, keep scene" stays offered and leaves the stop without a reset.
    func testReleaseKeepSceneLeavesTheStopWithNoRecorder() throws {
        try start(.keyTurns)
        hand.tap(x: hand.bottomBand.x, y: hand.bottomBand.y)
        XCTAssertTrue(hand.wait(2, until: { serverStopped }))
        hand.pump(1)
        XCTAssertEqual(model.stopExits.exits, [.resetScene, .releaseKeepScene])
        model.send(.releaseStop)
        XCTAssertFalse(model.session.state.emergencyStop)
        XCTAssertTrue(hand.wait(2, until: { !serverStopped }), "the server's stop was not released")
        hand.pump(1)
        XCTAssertFalse(model.session.state.emergencyStop, "the stop did not come back")
        XCTAssertEqual(server.inspect { $0.episode }, 0, "the scene was kept")
    }

    // MARK: What ends a hold

    func testOpeningSettingsEndsAHold() throws {
        try start(.screenTurns)
        hand.press(.upper)
        XCTAssertTrue(model.session.state.armMoving)
        model.send(.openSettings)
        XCTAssertFalse(model.session.state.armMoving, "Settings ends the hold")
        XCTAssertNil(model.controller.engagedHold)
        hand.pump(1)
        let armAtSettings = server.inspect { $0.world.arm }
        hand.move(to: SIMD3(0, 0.04, 0), in: 0.4)
        hand.pump(1)
        XCTAssertEqual(server.inspect { $0.world.arm }, armAtSettings, "moving the phone moves nothing")
        hand.release(.upper)
        model.send(.settingsDone)
        hand.position = .zero
        hand.pump(0.5)
        hand.press(.upper)
        XCTAssertTrue(model.session.state.armMoving, "a new press works after Settings closes")
        hand.release(.upper)
    }

    /// Connecting from Connect lands on P5, which the same operating screen draws, so Settings ends a hold there too.
    func testOpeningSettingsEndsAHoldWhereConnectLands() throws {
        try start(.screenTurns)
        model.send(.changeServer)
        model.send(.s1Back)
        XCTAssertEqual(model.session.route, .p5)
        XCTAssertTrue(model.session.state.connected)
        hand.pump(0.5)
        hand.press(.upper)
        XCTAssertTrue(model.session.state.armMoving)
        model.send(.openSettings)
        XCTAssertEqual(model.session.route, .s6)
        XCTAssertFalse(model.session.state.armMoving, "Settings ends the hold")
        XCTAssertNil(model.controller.engagedHold)
        hand.release(.upper)
    }

    func testLeavingTheForegroundEndsAHoldAndTheKeyHeldAcrossStaysDead() throws {
        try start(.screenTurns)
        hand.press(.upper)
        XCTAssertTrue(model.session.state.armMoving)
        model.activeChanged(false)
        XCTAssertFalse(model.session.state.armMoving, "leaving the app ends the hold")
        hand.pump(0.5)
        model.activeChanged(true)
        // The key was held all along; the system delivers its began again on return.
        hand.press(.upper)
        XCTAssertFalse(model.session.state.armMoving, "a key held across leaving stays dead")
        XCTAssertTrue(heard(.refused(.deadInput)))
        XCTAssertEqual(model.operating.state, .refused(.deadInput), "the refusal reaches the screen")
        hand.release(.upper)
        hand.pump(0.3)
        hand.press(.upper)
        XCTAssertTrue(model.session.state.armMoving, "a fresh press works")
        hand.release(.upper)
        XCTAssertFalse(model.session.state.armMoving)
    }

    /// ARKit stopping the camera, as `PoseTracker` reports it, ends the hold and the screen says so.
    func testTheCameraStoppingEndsAHoldAndReachesTheScreen() throws {
        try start(.screenTurns)
        hand.press(.upper)
        XCTAssertTrue(model.session.state.armMoving)
        PoseTracker.shared.onInterruption?(true)
        XCTAssertFalse(model.session.state.armMoving, "the camera stopping ends the hold")
        XCTAssertEqual(model.operating.state, .trackingLost)
        hand.release(.upper)
        PoseTracker.shared.onInterruption?(false)
        hand.pump(0.3)
        XCTAssertEqual(model.operating.state, .ready)
    }
}
