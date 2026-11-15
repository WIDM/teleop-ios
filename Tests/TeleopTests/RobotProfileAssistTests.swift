import simd
import TeleopCore
import XCTest
@testable import Teleop

/// A socket that keeps what the app sends and lets the test speak for the server.
private final class ProfileTestTransport: LinkTransport {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?

    func open() {}
    func close() {}
    func send(_ text: String) {}

    func server(_ type: String, _ payload: [String: Any] = [:]) {
        let message: [String: Any] = ["v": 1, "type": type, "ts": 0, "seq": 0, "payload": payload]
        onText?(String(data: try! JSONSerialization.data(withJSONObject: message), encoding: .utf8)!)
    }
}

/// The robot's share of the hands-free aids: every number is the profile's, a robot that allows none of them is the
/// master switch off for lock and taps, and the profile the model was given is the one the link judges the jaws by.
final class RobotProfileAssistTests: XCTestCase {
    private let profile = RobotProfile.so101Simulator

    /// The level leg of a move to a tapped point runs at the travel height, so that height has to lie inside the box
    /// the server keeps the pinch point in, or every tap would be refused.
    func testTheTravelHeightIsInsideTheBox() throws {
        let goTo = try XCTUnwrap(profile.assist.goTo)
        let height = Double(profile.tableHeight) + goTo.travelHeightM
        XCTAssertGreaterThan(height, Double(profile.workspaceMin.z))
        XCTAssertLessThan(height, Double(profile.workspaceMax.z))
    }

    /// A move counts as arrived inside this distance. It must be closer than the distance at which the feedback
    /// already calls a stalled arm blocked, or a move could arrive at a place the arm never reached.
    func testTheArrivalToleranceIsUnderTheBlockedDistance() throws {
        let goTo = try XCTUnwrap(profile.assist.goTo)
        XCTAssertLessThan(goTo.arriveToleranceM, FeedbackMonitor.blockedShortMeters)
    }

    /// A going move ends "time is up" this long after its path's own time, times the factor: room for an arm that lags
    /// behind the command and for a start the server takes late, so that a move nothing blocks arrives before it.
    func testTheGoAllowanceIsAtLeastThreeSeconds() throws {
        let goTo = try XCTUnwrap(profile.assist.goTo)
        XCTAssertGreaterThanOrEqual(goTo.allowanceS, 3)
    }

    /// The longest path a move can take in the box: from the farther of the box's floor and top to the travel height,
    /// then across the box's diagonal. Its time limit, less its time at the profile's speed, leaves room for one
    /// re-sent start: the link waits up to its resync timeout for the stopped hold's last answer before it starts
    /// again.
    func testTheGoLimitLeavesRoomForOneResentStart() throws {
        let goTo = try XCTUnwrap(profile.assist.goTo)
        let low = SIMD3<Double>(profile.workspaceMin), high = SIMD3<Double>(profile.workspaceMax)
        let travel = Double(profile.tableHeight) + goTo.travelHeightM
        let path = max(travel - low.z, high.z - travel) + simd_length(SIMD2(high.x - low.x, high.y - low.y))
        let atSpeed = path / goTo.speedMps
        // The deadline of a going move: the path's length over the speed, times the factor, plus the allowance.
        let limit = atSpeed * goTo.timeFactor + goTo.allowanceS
        XCTAssertGreaterThanOrEqual(limit - atSpeed, Double(LiveLinkController.resyncTimeoutMs) / 1000)
    }

    /// The SO-101 allows every aid, with numbers the configuration accepts: lock for 30 s once the operator chooses a
    /// variant, taps, and all of the guide's additions. Its on-target window stays the grasp tolerance until chosen.
    func testTheSO101AllowsEveryAid() {
        let assist = Assist.resolve(masterOn: true, lockChoice: .pressPress, profile: profile.assist)
        XCTAssertEqual(assist.lock, LockRule(variant: .pressPress, timeLimitS: 30))
        XCTAssertEqual(assist.goTo, profile.assist.goTo)
        XCTAssertEqual(assist.guide, .all)
        XCTAssertNil(profile.onTargetWindow)
    }

    /// A robot whose profile allows no aid resolves lock and taps away whatever the operator chooses, as the master
    /// switch off does; a profile that says nothing about the aids allows none.
    func testARobotThatAllowsNoAidsResolvesLockAndTapsAway() {
        var bare = profile
        bare.assist = .none
        for choice in LockChoice.allCases {
            let assist = Assist.resolve(masterOn: true, lockChoice: choice, profile: bare.assist)
            XCTAssertNil(assist.lock, "\(choice)")
            XCTAssertNil(assist.goTo, "\(choice)")
        }
        let unsaid = RobotProfile(name: "test", toolOffset: SIMD3(0, 0, -0.10), baseInWorld: SIMD3(0, 0, 0.05))
        XCTAssertEqual(unsaid.assist, .none)
        XCTAssertNil(unsaid.onTargetWindow)
    }

    /// "Fully open" is felt at the opening angle of the profile the model was given, not the SO-101's: a robot whose
    /// jaws open only to 50 degrees hears it at 60, the SO-101 (97 degrees) does not.
    func testTheLinkJudgesTheJawsByTheModelsProfile() {
        var narrow = profile
        narrow.gripperOpenDeg = 50
        XCTAssertTrue(heardFullyOpen(atDegrees: 60, profile: narrow))
        XCTAssertFalse(heardFullyOpen(atDegrees: 60, profile: profile))
    }

    /// Opens the jaws on a real server that then reports them at `degrees`, and says whether "fully open" was raised.
    private func heardFullyOpen(atDegrees degrees: Double, profile: RobotProfile) -> Bool {
        var control: ProfileTestTransport?
        let model = AppModel(
            start: .p4,
            haptics: SpyHaptics(),
            sounds: SpySounds(),
            speech: SpySpeech(),
            pose: { TestPose.portrait(at: .zero) },
            liveLink: true,
            makeTransport: { _ in
                let made = ProfileTestTransport()
                control = made
                return made
            },
            makeObserverTransport: { _ in ProfileTestTransport() },
            nowMs: { 10_000 },
            clientName: "teleop-ios/1.0.0 (7)",
            profile: profile
        )
        model.session.state.serverAddress = "100.64.0.1:8765"
        model.connect()
        control?.server("welcome")
        control?.server("state", ["estop": false, "gripper": "closed", "gripper_deg": 0.0])
        model.send(.gripperStart(.open))
        XCTAssertEqual(model.session.state.gripperMoving, .open)
        control?.server("state", ["estop": false, "gripper": "open", "gripper_deg": degrees])
        model.send(.gripperEnd)
        return model.cueLog.contains { $0.event == .limit(.fullyOpen) }
    }
}
