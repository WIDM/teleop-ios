import simd
import TeleopCore
import XCTest
@testable import Teleop

private final class WindowTestTransport: LinkTransport {
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

/// The wider window for "On target": with the guide's aids on and a profile that gives one, the guide's "On target"
/// and the cue that is felt with it both use the profile's window. Without that aid, or with a profile that gives no
/// window, both use the grasp tolerance, as version 1.0.1 does. The level word keeps the grasp tolerance. A change of
/// the aids that changes the window makes a new cue, armed as after a reset; one that leaves the window as it was
/// leaves the cue alone.
final class OnTargetWindowTests: XCTestCase {
    /// The simulator with a window twice its grasp tolerance across and half as wide again in height.
    private static let wide: RobotProfile = {
        var profile = TestProfiles.so101
        profile.onTargetWindow = SIMD2(0.012, 0.012)
        return profile
    }()

    private var control: WindowTestTransport?
    private var clock = 10_000
    private var savedTaskAid: Any?

    override func setUp() {
        super.setUp()
        savedTaskAid = UserDefaults.standard.object(forKey: AppModel.taskAidKey)
    }

    /// Both of the aids' settings are removed, never put back: a launch argument shadows the saved value, so a value
    /// read here and written back could be the argument's, saved for good.
    override func tearDown() {
        UserDefaults.standard.set(savedTaskAid, forKey: AppModel.taskAidKey)
        UserDefaults.standard.removeObject(forKey: AppModel.assistKey)
        UserDefaults.standard.removeObject(forKey: AppModel.lockChoiceKey)
        control = nil
        super.tearDown()
    }

    private static let noWiderWindow = GuideAids(
        workAreaWords: true, lowestCue: true, shadow: true, directionLabels: true, widerOnTarget: false)

    /// The pinch point `across` metres to the side of the target and `above` metres over it, jaws open.
    private func reading(across: Float, above: Float, approximate: Bool = false) -> ArmReading {
        let profile = TestProfiles.so101
        let target = (profile.workspaceMin + profile.workspaceMax) / 2
        var reading = ArmReading(
            pinchPoint: target + SIMD3(across, 0, above), commanded: nil, jawOpening: 0.7, wristTurnDeg: 90,
            wristTiltDeg: 0, target: target, goal: nil, gripping: false)
        if approximate { reading.pinchSource = .estimated(approximate: true) }
        return reading
    }

    private func onTargetLine(_ picture: GuidePicture) -> Bool { picture.lines.contains(.onTarget) }

    func testTheWindowIsTheProfilesOnlyWithItsAid() {
        let tolerance = SIMD2<Double>(TestProfiles.so101.graspTolerance)
        XCTAssertEqual(GuidePicture.onTargetWindow(Self.wide, aids: .all), SIMD2<Double>(Self.wide.onTargetWindow!))
        XCTAssertEqual(GuidePicture.onTargetWindow(Self.wide, aids: nil), tolerance)
        XCTAssertEqual(GuidePicture.onTargetWindow(Self.wide, aids: Self.noWiderWindow), tolerance)
        XCTAssertEqual(GuidePicture.onTargetWindow(TestProfiles.so101, aids: .all), tolerance, "the profile gives none")
    }

    /// 9 mm across is outside the grasp tolerance's 6 mm and inside the wider window's 12 mm.
    func testTheGuidesOnTargetUsesTheWiderWindowOnlyWithItsAid() {
        let nine = reading(across: 0.009, above: 0.003)
        let wider = GuidePicture(reading: nine, profile: Self.wide, aids: .all)
        XCTAssertTrue(wider.onTarget)
        XCTAssertTrue(onTargetLine(wider))
        let narrow: [(RobotProfile, GuideAids?)] = [
            (Self.wide, nil), (Self.wide, Self.noWiderWindow), (TestProfiles.so101, .all),
        ]
        for (profile, aids) in narrow {
            let picture = GuidePicture(reading: nine, profile: profile, aids: aids)
            XCTAssertFalse(picture.onTarget, "\(String(describing: aids))")
            XCTAssertFalse(onTargetLine(picture), "\(String(describing: aids))")
        }
        let thirteen = GuidePicture(reading: reading(across: 0.013, above: 0), profile: Self.wide, aids: .all)
        XCTAssertFalse(thirteen.onTarget, "outside the wider window too")
        let high = GuidePicture(reading: reading(across: 0, above: 0.013), profile: Self.wide, aids: .all)
        XCTAssertFalse(high.onTarget, "too high for the wider window")
        let approximate = reading(across: 0.009, above: 0, approximate: true)
        XCTAssertFalse(GuidePicture(reading: approximate, profile: Self.wide, aids: .all).onTarget, "never approximate")
    }

    /// Only "On target" widens: 10 mm above the target is inside the wider window's height but still "1 cm above",
    /// as the grasp tolerance's 8 mm says, and every other line is as without the aid.
    func testTheLevelWordKeepsTheGraspTolerance() {
        let tenAbove = reading(across: 0.002, above: 0.010)
        let wider = GuidePicture(reading: tenAbove, profile: Self.wide, aids: .all)
        let version101 = GuidePicture(reading: tenAbove, profile: Self.wide, aids: nil)
        XCTAssertTrue(wider.onTarget)
        XCTAssertFalse(version101.onTarget)
        let target = wider.lines.first { if case .target = $0 { true } else { false } }
        guard case .target(_, .above(let cm))? = target else { return XCTFail("\(wider.lines)") }
        XCTAssertEqual(cm, 1, accuracy: 1e-4)
        XCTAssertEqual(wider.lines.filter { $0 != .onTarget }, version101.lines)
    }

    /// The model, against a scripted server, with the pinch point exactly where the profile measured its offset and
    /// the task object `across` metres to the side of it.
    private func model(_ profile: RobotProfile, aids: Bool) -> (AppModel, SpyHaptics) {
        clock = 10_000
        let felt = SpyHaptics()
        let model = AppModel(
            start: .p4, haptics: felt, sounds: SpySounds(), speech: SpySpeech(), pose: { TestPose.portrait },
            liveLink: true,
            makeTransport: { [unowned self] _ in
                let made = WindowTestTransport()
                control = made
                return made
            },
            makeObserverTransport: { _ in WindowTestTransport() },
            nowMs: { [unowned self] in clock }, profile: profile, assistOn: aids, lockChoice: .off
        )
        model.taskAid = true
        model.session.state.serverAddress = "100.64.0.1:8765"
        model.connect()
        control?.server("welcome")
        return (model, felt)
    }

    private func objectAt(across: Double, _ model: AppModel) {
        clock += 500
        let grasp = SIMD3<Double>(model.profile.offsetMeasuredAt)
        let object = grasp + SIMD3<Double>(model.profile.toolOffset + model.profile.baseInWorld) + SIMD3(across, 0, 0)
        control?.server(
            "state",
            [
                "estop": false, "gripper": "open", "episode": 0, "ee_pos": [grasp.x, grasp.y, grasp.z],
                "object_pos": [object.x, object.y, object.z],
                "wrist_flex_deg": model.profile.offsetMeasuredFlexDeg,
                "wrist_roll_deg": model.profile.offsetMeasuredRollDeg,
            ])
    }

    private func onTargetFelt(_ felt: SpyHaptics) -> Int { felt.felt.filter { $0 == .play(.onTarget) }.count }

    /// The cue is felt as the drawn "On target" turns true: at 9 mm with the wider window, not without the aids.
    func testTheCueIsFeltInTheWindowTheGuideDraws() {
        for aids in [true, false] {
            let (model, felt) = model(Self.wide, aids: aids)
            objectAt(across: 0.02, model)
            XCTAssertEqual(model.operating.guide?.onTarget, false, "aids \(aids)")
            objectAt(across: 0.009, model)
            XCTAssertEqual(model.operating.guide?.onTarget, aids, "aids \(aids)")
            XCTAssertEqual(onTargetFelt(felt), aids ? 1 : 0, "aids \(aids)")
        }
    }

    /// Turning the aids off narrows the window: a new cue, armed, is felt at 3 mm. Kept, the felt cue would have stayed
    /// silent, since 3 mm never left its wider window.
    func testAChangeOfTheAidsThatChangesTheWindowMakesANewCue() {
        let (model, felt) = model(Self.wide, aids: true)
        objectAt(across: 0.02, model)
        objectAt(across: 0.009, model)
        XCTAssertEqual(onTargetFelt(felt), 1)
        model.assistOn = false
        XCTAssertFalse(model.assistOn)
        XCTAssertEqual(onTargetFelt(felt), 1, "9 mm is outside the narrower window")
        objectAt(across: 0.003, model)
        XCTAssertEqual(model.operating.guide?.onTarget, true)
        XCTAssertEqual(onTargetFelt(felt), 2, "felt by the new cue")
    }

    /// With a profile that gives no window, switching the aids leaves the window, and so the cue, as it was: no second
    /// cue for jaws that never left the target.
    func testAChangeOfTheAidsThatLeavesTheWindowKeepsTheCue() {
        let (model, felt) = model(TestProfiles.so101, aids: true)
        objectAt(across: 0.02, model)
        objectAt(across: 0.003, model)
        XCTAssertEqual(onTargetFelt(felt), 1)
        model.assistOn = false
        objectAt(across: 0.003, model)
        model.assistOn = true
        objectAt(across: 0.003, model)
        XCTAssertEqual(model.operating.guide?.onTarget, true)
        XCTAssertEqual(onTargetFelt(felt), 1)
    }
}
