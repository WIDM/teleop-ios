import simd
import TeleopCore
import XCTest
@testable import Teleop

final class RobotProfileTests: XCTestCase {
    /// The profile brings the server's two frames together: the arm point is moved to where the jaws pinch, and objects
    /// reported in the world frame are moved into the robot base frame.
    func testTheProfileMovesTheToolPointAndTheObjects() {
        // A gripper that pinches straight below the reported point, on a robot sitting 5 cm above the world origin.
        let straightDown = RobotProfile(name: "test", toolOffset: SIMD3(0, 0, -0.10), baseInWorld: SIMD3(0, 0, 0.05))
        XCTAssertLessThan(simd_distance(straightDown.toolPoint(reported: SIMD3(0.01, -0.2, 0.15)), SIMD3(0.01, -0.2, 0.05)), 1e-6)
        XCTAssertLessThan(simd_distance(straightDown.inBase(world: SIMD3(0.01, -0.2, 0.10)), SIMD3(0.01, -0.2, 0.05)), 1e-6)
    }
}

final class PhonePostureTests: XCTestCase {
    private func pitchedBack(_ degrees: Float) -> simd_float4x4 {
        TestPose.portrait(turned: -degrees, about: SIMD3(1, 0, 0))
    }

    private func rolled(_ degrees: Float) -> simd_float4x4 {
        TestPose.portrait(turned: degrees, about: SIMD3(0, 0, 1))
    }

    func testUprightPhoneIsFine() {
        XCTAssertEqual(PhonePosture.of(TestPose.portrait), .upright)
        XCTAssertEqual(PhonePosture.of(TestPose.portrait(turned: 115, about: SIMD3(0, 1, 0))), .upright, "facing another way is still fine")
    }

    func testLeaningBackIsFineAllTheWayToFlat() {
        for degrees: Float in [30, 45, 60, 75, 90] {
            XCTAssertEqual(PhonePosture.of(pitchedBack(degrees)), .upright, "\(degrees) degrees back")
        }
    }

    func testSmallRollIsFineButSidewaysIsNot() {
        XCTAssertEqual(PhonePosture.of(rolled(25)), .upright)
        XCTAssertEqual(PhonePosture.of(rolled(-25)), .upright)
        XCTAssertEqual(PhonePosture.of(rolled(60)), .tilted)
        XCTAssertEqual(PhonePosture.of(rolled(90)), .tilted)
        XCTAssertEqual(PhonePosture.of(rolled(-90)), .tilted)
    }

    func testScreenTowardTheFloorIsNotFine() {
        XCTAssertEqual(PhonePosture.of(pitchedBack(-20)), .upright, "a slight forward lean is fine")
        XCTAssertEqual(PhonePosture.of(pitchedBack(-50)), .tilted)
        XCTAssertEqual(PhonePosture.of(pitchedBack(-90)), .tilted)
    }

    func testUpsideDownOrNoPoseIsNotFine() {
        XCTAssertEqual(PhonePosture.of(rolled(180)), .tilted)
        XCTAssertEqual(PhonePosture.of(nil), .unknown)
    }
}

/// A translation pressed while the phone is held wrong is refused and says why.
final class PostureRefusalTests: XCTestCase {
    private var camera: simd_float4x4? = TestPose.portrait
    private var spy: SpyHaptics!
    private var model: AppModel!

    private var savedLanguage = L10n.language

    override func setUp() {
        camera = TestPose.portrait
        spy = SpyHaptics()
        model = AppModel(start: .p4, haptics: spy, pose: { [unowned self] in camera }, liveLink: false)
        savedLanguage = L10n.language
        L10n.language = .en
    }

    override func tearDown() {
        L10n.language = savedLanguage
        super.tearDown()
    }

    private var sideways: simd_float4x4 { TestPose.portrait(turned: 90, about: SIMD3(0, 0, 1)) }

    func testATranslationWithThePhoneHeldSidewaysIsRefused() {
        let speech = SpySpeech()
        let live = AppModel(
            start: .p4, haptics: spy, speech: speech, pose: { [unowned self] in camera }, liveLink: true,
            makeTransport: { _ in SilentTransport() }
        )
        live.session.state.markConnected()
        camera = sideways
        live.send(.holdArmStart)
        XCTAssertFalse(live.session.state.armMoving)
        XCTAssertEqual(spy.felt, [.play(.no)])
        XCTAssertEqual(speech.spoken, ["Hold the phone upright."])
    }
}

/// A socket that is never answered.
final class SilentTransport: LinkTransport {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    func open() {}
    func send(_ text: String) {}
    func close() {}
}
