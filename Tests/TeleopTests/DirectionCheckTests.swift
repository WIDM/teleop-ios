import simd
import TeleopCore
import TeleopServerHost
import TeleopServerModel
import XCTest
@testable import Teleop

/// The direction check (`DirectionCheck`) against the in-app server model, for the SO-101 and bench arm B, and its
/// judgement on moves made up by hand. `OperatorLiveTests` runs the same check against a real server.
final class DirectionCheckTests: XCTestCase {
    private var server: LocalTeleopServer!
    private var hand: ScriptedOperator!

    override func tearDown() {
        hand?.finish()
        if hand != nil, let server {
            XCTAssertTrue(server.waitForTheAppsSocketsToClose(), "the server still holds \(server.openSockets) sockets")
        }
        hand = nil
        server?.stop()
        server = nil
    }

    /// The server model for `profile`, and an app that believes `appProfile` (the same unless a test plants a fault).
    private func start(serverFor profile: RobotProfile, appProfile: RobotProfile? = nil) throws {
        let config: ServerModelConfig
        if profile.gripper.unit == .mm {
            config = try BenchArmB.config(for: profile)
        } else {
            config = try .s4Simulator(stepsPerSecond: 60).settingFrames(from: profile.frames)
        }
        server = LocalTeleopServer(config: config)
        try server.start()
        hand = ScriptedOperator(
            address: server.address, mode: .buttons, smoothing: 0.3, pace: 0.3, profile: appProfile ?? profile)
        XCTAssertTrue(hand.connect(within: TestWaits.linkUp), "could not connect to the local server")
        _ = try XCTUnwrap(hand.model.link.armPosition, "the local server reported no arm position")
    }

    private func check(_ profile: RobotProfile, as app: RobotProfile? = nil) throws -> [String] {
        try start(serverFor: profile, appProfile: app)
        let moves = try XCTUnwrap(hand.directionMoves(), "the check could not read the arm")
        XCTAssertEqual(moves.map(\.direction), OperatorDirection.allCases, "all six directions, in this order")
        return moves.compactMap(DirectionCheck.fault)
    }

    // MARK: Against the server model

    func testEveryDirectionGoesTheNamedWayForEachProfile() throws {
        for (name, profile) in [("SO-101", TestProfiles.so101), ("bench arm B", TestProfiles.benchB)] {
            let faults = try check(profile)
            XCTAssertEqual(faults, [], name)
            hand.finish()
            hand = nil
            server.stop()
            server = nil
        }
    }

    /// B's file with the sign of the link's z written the wrong way: "up" and "down" go the other way, and the
    /// message names the directions and the axis the arm went along instead.
    func testAPlantedWrongSignInBsFileFailsTheCheck() throws {
        var wrong = TestProfiles.benchB
        wrong.frames.linkSigns.z = -wrong.frames.linkSigns.z
        let faults = try check(TestProfiles.benchB, as: wrong)
        XCTAssertEqual(faults.count, 2, "\(faults)")
        let up = try XCTUnwrap(faults.first { $0.hasPrefix("up:") }, "\(faults)")
        XCTAssertTrue(up.contains("wrong way"), up)
        XCTAssertTrue(up.contains("base -z") || up.contains("base +z"), up)
        XCTAssertTrue(faults.contains { $0.hasPrefix("down:") }, "\(faults)")
    }

    /// The app's profile names the wrong axis for left and right: the arm goes where the app sends it, along the other
    /// axis, and the message says which.
    func testAPlantedWrongLinkSignOnAnotherAxisIsNamed() throws {
        var wrong = TestProfiles.so101
        wrong.frames.linkSigns.x = -wrong.frames.linkSigns.x
        let faults = try check(TestProfiles.so101, as: wrong)
        XCTAssertEqual(faults.count, 2, "\(faults)")
        XCTAssertTrue(faults.allSatisfy { $0.hasPrefix("left:") || $0.hasPrefix("right:") }, "\(faults)")
    }

    /// What the check cannot see: a profile that names forward as the wrong way along its axis. The app sends what the
    /// profile says, so the arm goes there and the read-back agrees. Only a person watching the arm sees that it goes
    /// toward them (docs/PROFILE.md says to look).
    func testTheCheckCannotTellWhichWayForwardPointsInTheRoom() throws {
        var wrong = TestProfiles.so101
        wrong.frames.forward = wrong.frames.forward.reversed
        wrong.frames.left = wrong.frames.left.reversed
        XCTAssertEqual(try check(TestProfiles.so101, as: wrong), [])
    }

    // MARK: The judgement

    private func fault(_ direction: OperatorDirection, expected: SignedAxis, _ cm: SIMD3<Double>) -> String? {
        DirectionCheck.fault(.init(direction: direction, expected: expected, delta: cm / 100))
    }

    func testJudgement() throws {
        let forward = SignedAxis(.y, -1)
        XCTAssertNil(fault(.forward, expected: forward, SIMD3(0, -1, 0)))
        XCTAssertNil(fault(.forward, expected: forward, SIMD3(0.1, -0.8, 0.2)), "a little off-axis is allowed")
        XCTAssertNil(fault(.forward, expected: forward, SIMD3(0, -0.6, 0)), "6 mm of 10 is still along it")

        let wrongWay = try XCTUnwrap(fault(.forward, expected: forward, SIMD3(0, 1, 0)))
        XCTAssertTrue(wrongWay.hasPrefix("forward:") && wrongWay.contains("wrong way"), wrongWay)
        XCTAssertTrue(wrongWay.contains("base +y"), wrongWay)

        let other = try XCTUnwrap(fault(.forward, expected: forward, SIMD3(1, 0, 0)))
        XCTAssertTrue(other.hasPrefix("forward:"), other)
        XCTAssertTrue(other.contains("along base +x") && other.contains("instead"), other)

        let still = try XCTUnwrap(fault(.forward, expected: forward, SIMD3(0, -0.1, 0)))
        XCTAssertTrue(still.contains("did not move"), still)

        let sideways = try XCTUnwrap(fault(.up, expected: SignedAxis(.z, 1), SIMD3(0.5, 0, 1)))
        XCTAssertTrue(sideways.contains("also went") && sideways.contains("base +x"), sideways)

        let far = try XCTUnwrap(fault(.up, expected: SignedAxis(.z, 1), SIMD3(0, 0, 3)))
        XCTAssertTrue(far.contains("fine_mps"), far)
    }
}
