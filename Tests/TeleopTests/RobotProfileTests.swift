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
        let estimated = straightDown.pinchPoint(gripper: SIMD3(0.01, -0.2, 0.15), tool: nil, flexDeg: nil, rollDeg: nil)
        XCTAssertLessThan(simd_distance(estimated.point, SIMD3(0.01, -0.2, 0.05)), 1e-6)
        XCTAssertEqual(estimated.offset, straightDown.toolOffset)
        XCTAssertLessThan(
            simd_distance(straightDown.inBase(world: SIMD3(0.01, -0.2, 0.10)), SIMD3(0.01, -0.2, 0.05)), 1e-6)
    }

    /// A reported tool point wins over the estimate, and the offset that moves the command and the box is the one
    /// measured in the same reading. It is never approximate, however far from where the offset was measured.
    func testAReportedToolPointIsPreferred() {
        let profile = RobotProfile.so101Simulator
        let gripper = SIMD3<Float>(0.02, -0.14, 0.16), tool = SIMD3<Float>(0.03, -0.17, 0.08)
        for wrist in [(Double?.none, Double?.none), (70, 30)] {
            let pinch = profile.pinchPoint(gripper: gripper, tool: tool, flexDeg: wrist.0, rollDeg: wrist.1)
            XCTAssertEqual(pinch.point, tool)
            XCTAssertEqual(pinch.source, .reported)
            XCTAssertLessThan(simd_distance(pinch.offset, tool - gripper), 1e-7)
        }
    }

    /// A finite number too large for a `Float` arrives as infinity. A tool point or gripper point like that gives no
    /// offset to move the box by, so the tool point counts as not reported.
    func testAToolPointBeyondFloatRangeIsNotUsed() {
        let profile = RobotProfile.so101Simulator
        let gripper = SIMD3<Float>(0.02, -0.14, 0.16), tool = SIMD3<Float>(0.03, -0.17, 0.08)
        for (g, t) in [(gripper, SIMD3(Float(1e39), -0.17, 0.08)), (SIMD3(Float(-1e39), -0.14, 0.16), tool)] {
            let pinch = profile.pinchPoint(gripper: g, tool: t, flexDeg: 40.24, rollDeg: 90)
            XCTAssertEqual(pinch.source, .estimated(approximate: true))
            XCTAssertEqual(pinch.offset, profile.toolOffset)
        }
    }

    // MARK: The estimate's accuracy rule

    private let profile = RobotProfile.so101Simulator

    /// Moved by `centimetres` from where the offset was measured, the wrist moved by `flex` and `roll` degrees.
    private func source(_ centimetres: SIMD3<Float> = .zero, flex: Double = 0, roll: Double = 0) -> PinchSource {
        profile.pinchPoint(
            gripper: profile.offsetMeasuredAt + centimetres / 100, tool: nil,
            flexDeg: profile.offsetMeasuredFlexDeg + flex, rollDeg: profile.offsetMeasuredRollDeg + roll
        ).source
    }

    /// Where the offset was measured the estimate is exact, and the cube's resting centre is the pinch point there.
    func testTheEstimateIsExactWhereTheOffsetWasMeasured() {
        XCTAssertEqual(profile.estimateError(gripper: profile.offsetMeasuredAt, flexDeg: 40.24, rollDeg: 90), 0)
        XCTAssertEqual(source(), .estimated(approximate: false))
        let cube = profile.inBase(world: SIMD3(0.005, -0.2, 0.1025))
        XCTAssertLessThan(simd_distance(profile.offsetMeasuredAt + profile.toolOffset, cube), 1e-6)
    }

    /// Half the 6 mm window is 3 mm. Each term of the rule, just inside and just past that.
    func testTheEstimateTurnsApproximateAtHalfTheWindow() {
        XCTAssertEqual(profile.graspTolerance.x / 2, 0.003)
        let cases: [(String, inside: PinchSource, past: PinchSource)] = [
            ("across +x, 2.56 mm/cm", source(SIMD3(1.17, 0, 0)), source(SIMD3(1.18, 0, 0))),
            ("across −x", source(SIMD3(-1.17, 0, 0)), source(SIMD3(-1.18, 0, 0))),
            ("toward the base, 11.12 mm/cm", source(SIMD3(0, 0.26, 0)), source(SIMD3(0, 0.28, 0))),
            ("away from the base, 1.80 mm/cm", source(SIMD3(0, -1.66, 0)), source(SIMD3(0, -1.68, 0))),
            ("up, 8.43 mm/cm", source(SIMD3(0, 0, 0.35)), source(SIMD3(0, 0, 0.36))),
            ("down, as up", source(SIMD3(0, 0, -0.35)), source(SIMD3(0, 0, -0.36))),
            ("tilt, 1.65 mm/°", source(flex: 1.8), source(flex: 1.83)),
            ("tilt the other way", source(flex: -1.8), source(flex: -1.83)),
            ("turn, 0.23 mm/°", source(roll: 13), source(roll: 13.1)),
            ("terms add", source(SIMD3(0.5, 0, 0.1), flex: 0.5), source(SIMD3(0.5, 0, 0.1), flex: 0.6)),
        ]
        for (what, inside, past) in cases {
            XCTAssertEqual(inside, .estimated(approximate: false), what)
            XCTAssertEqual(past, .estimated(approximate: true), what)
        }
        let error = profile.estimateError(
            gripper: profile.offsetMeasuredAt + SIMD3(0.01, 0.002, -0.003), flexDeg: 42.24, rollDeg: 80)
        // One term each, in mm: 1 cm across, 0.2 cm toward the base, 0.3 cm down, 2° of tilt, 10° of turn.
        let terms: [Float] = [2.56 * 1, 11.12 * 0.2, 8.43 * 0.3, 1.65 * 2, 0.23 * 10]
        XCTAssertEqual(error ?? 0, terms.reduce(0, +) / 1000, accuracy: 1e-6)
    }

    /// Without both wrist angles a tilt cannot be ruled out, so the estimate is approximate even where it was measured.
    func testAnEstimateWithoutTheWristAnglesIsApproximate() {
        for (flex, roll) in [(Double?.none, Double?.none), (40.24, nil), (nil, 90)] {
            XCTAssertNil(profile.estimateError(gripper: profile.offsetMeasuredAt, flexDeg: flex, rollDeg: roll))
            let pinch = profile.pinchPoint(gripper: profile.offsetMeasuredAt, tool: nil, flexDeg: flex, rollDeg: roll)
            XCTAssertEqual(pinch.source, .estimated(approximate: true))
        }
    }

    /// The places of the research note: right after a reset the drawn point is 3 cm off, and a cube nudged 4 cm
    /// sideways is 9 to 10 mm off. The rule calls both approximate; a 1 cm nudge across stays solid.
    func testThePlacesFromTheHandSessions() {
        let afterReset = profile.pinchPoint(
            gripper: SIMD3(0.020617, -0.141418, 0.159985), tool: nil, flexDeg: 40.24, rollDeg: 90)
        XCTAssertEqual(afterReset.source, .estimated(approximate: true))
        XCTAssertEqual(source(SIMD3(4, 0, 0)), .estimated(approximate: true))
        XCTAssertEqual(source(SIMD3(1, 0, 0)), .estimated(approximate: false))
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
        XCTAssertEqual(
            PhonePosture.of(TestPose.portrait(turned: 115, about: SIMD3(0, 1, 0))), .upright,
            "facing another way is still fine")
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
