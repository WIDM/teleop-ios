import simd
import TeleopCore
import XCTest
@testable import Teleop

private final class GuideTestTransport: LinkTransport {
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

/// The guide is built once per refresh, from the arm reading and the guide's aids in force, and carried in the display:
/// the screen draws that picture and the on-target cue judges by it, so the two cannot disagree. Fixtures carry theirs
/// the same way, each with the aids it draws.
final class SingleGuidePictureTests: XCTestCase {
    /// The fixtures that draw the guide's aids, and which; every other fixture draws none.
    private static let fixtureAids: [String: GuideAids] = ["ready_aids": .all, "lowest_aids": .all]

    private var control: GuideTestTransport?
    private var clock = 10_000
    private var savedTaskAid: Any?

    override func setUp() {
        super.setUp()
        savedTaskAid = UserDefaults.standard.object(forKey: AppModel.taskAidKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(savedTaskAid, forKey: AppModel.taskAidKey)
        control = nil
        super.tearDown()
    }

    func testTheDisplayCarriesThePictureTheOnTargetCueReads() {
        let felt = SpyHaptics()
        let model = AppModel(
            start: .p4, haptics: felt, sounds: SpySounds(), speech: SpySpeech(), pose: { TestPose.portrait },
            liveLink: true,
            makeTransport: { [unowned self] _ in
                let made = GuideTestTransport()
                control = made
                return made
            },
            makeObserverTransport: { _ in GuideTestTransport() },
            nowMs: { [unowned self] in clock }
        )
        model.taskAid = true
        let assist = model.assist
        XCTAssertNil(model.operating.guide, "no arm reported yet")
        model.session.state.serverAddress = "100.64.0.1:8765"
        model.connect()
        control?.server("welcome")
        control?.server("state", armState(model, above: 0.02))
        let above = model.operating.guide
        XCTAssertNotNil(above)
        XCTAssertEqual(
            above,
            model.operating.arm.map {
                GuidePicture(reading: $0, profile: model.profile, aids: assist.guide, views: assist.views)
            })
        XCTAssertEqual(above?.fixedLayout, assist.views != nil)
        XCTAssertEqual(above?.onTarget, false)
        XCTAssertEqual(felt.felt.filter { $0 == .play(.onTarget) }.count, 0)

        clock += 1000
        control?.server("state", armState(model, above: 0))
        let on = model.operating.guide
        XCTAssertEqual(
            on,
            model.operating.arm.map {
                GuidePicture(reading: $0, profile: model.profile, aids: assist.guide, views: assist.views)
            })
        XCTAssertEqual(on?.onTarget, true)
        XCTAssertEqual(
            felt.felt.filter { $0 == .play(.onTarget) }.count, 1, "felt as the drawn picture turns On target")
    }

    func testEveryFixtureCarriesThePictureOfItsReading() {
        for (name, display) in OperatingFixtures.all {
            let aids = Self.fixtureAids[name]
            XCTAssertEqual(
                display.guide, display.arm.map { GuidePicture(reading: $0, profile: .so101Simulator, aids: aids) },
                name)
        }
        XCTAssertNotNil(OperatingFixtures.all["ready"]?.guide)
        XCTAssertEqual(OperatingFixtures.all["ready_aids"]?.guide?.directionLabels, true, "a fixture draws the aids")
        XCTAssertNil(OperatingFixtures.all["not_connected"]?.guide)
    }

    /// The gripper point where the profile's offset was measured, so the estimate is exact, `above` metres over the
    /// task object, with the jaws open.
    private func armState(_ model: AppModel, above: Double) -> [String: Any] {
        let grasp = SIMD3<Double>(model.profile.offsetMeasuredAt)
        let arm = grasp + SIMD3(0, 0, above)
        let object = grasp + SIMD3<Double>(model.profile.toolOffset + model.profile.baseInWorld)
        return [
            "estop": false, "gripper": "open", "episode": 0, "ee_pos": [arm.x, arm.y, arm.z],
            "object_pos": [object.x, object.y, object.z],
            "wrist_flex_deg": model.profile.offsetMeasuredFlexDeg,
            "wrist_roll_deg": model.profile.offsetMeasuredRollDeg,
        ]
    }
}
