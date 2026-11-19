import simd
import TeleopCore
import XCTest
@testable import Teleop

/// A socket that lets the test speak for the server and keeps nothing the app sends.
private final class FactsTestTransport: LinkTransport {
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

/// The aids' settings: the master switch and the lock choice. How they are read at launch, kept across launches,
/// refused while something is engaged, recorded in the developer log and handed to the input rules; and what the input
/// rules are told about the moment with tap-to-go allowed, and with the switch off.
final class AssistModelTests: XCTestCase {
    private var savedMode: String?
    private var savedTaskAid: Any?
    private var clock = 10_000
    private var transport: FactsTestTransport!

    /// About where the reference phone draws the guide's view from above.
    private static let panel = SurfaceLayout.Rect(x: 118, y: 262, width: 166, height: 166)

    override func setUp() {
        super.setUp()
        savedMode = UserDefaults.standard.string(forKey: AppModel.controlModeKey)
        savedTaskAid = UserDefaults.standard.object(forKey: AppModel.taskAidKey)
    }

    /// Both of the aids' settings are removed, never put back: a launch argument shadows the saved value, so a value
    /// read here and written back could be the argument's (the AssistOff plan's `-assist NO`), saved for good. The UI
    /// tests and every other test launch with neither saved. The task aid is put back as it was.
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppModel.assistKey)
        UserDefaults.standard.removeObject(forKey: AppModel.lockChoiceKey)
        UserDefaults.standard.set(savedMode, forKey: AppModel.controlModeKey)
        UserDefaults.standard.set(savedTaskAid, forKey: AppModel.taskAidKey)
        transport = nil
        super.tearDown()
    }

    /// Standby on the real server with the link up and the arm reported, the aids given to the model without saving
    /// them.
    private func liveModel(profile: RobotProfile = .so101Simulator, assistOn: Bool) -> AppModel {
        clock = 10_000
        let model = AppModel(
            start: .p4, haptics: NoHaptics(), sounds: SpySounds(), speech: SpySpeech(), pose: { TestPose.portrait },
            liveLink: true,
            makeTransport: { [unowned self] _ in
                let made = FactsTestTransport()
                transport = made
                return made
            },
            makeObserverTransport: { _ in FactsTestTransport() },
            nowMs: { [unowned self] in clock }, inputClock: { [unowned self] in Double(clock) / 1000 },
            clientName: "teleop-ios/1.0.0 (7)", profile: profile, assistOn: assistOn, lockChoice: .off)
        model.controlMode = .screenTurns
        model.session.state.serverAddress = "100.64.0.1:8765"
        model.connect()
        transport.server("welcome")
        transport.server("state", ["estop": false, "gripper": "open", "ee_pos": [0.02, -0.14, 0.16]])
        XCTAssertTrue(model.session.state.connected)
        return model
    }

    /// A launch argument arrives as the string "NO" or "YES", which a cast to Bool misses; the switch reads it. The
    /// key is one no launch argument sets: every set of defaults also searches the launch arguments, which in the
    /// AssistOff plan hold the switch's own key. `OffPlanTests` checks that one.
    func testANoLaunchArgumentTurnsTheMasterSwitchOff() throws {
        let name = "AssistModelTests.launchArgument"
        let key = "AssistModelTests.switch"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.removePersistentDomain(forName: name)
        XCTAssertTrue(AppModel.savedBool(key, default: true, defaults), "nothing saved: on")
        defaults.set("NO", forKey: key)
        XCTAssertNil(defaults.object(forKey: key) as? Bool, "a cast to Bool misses the argument")
        XCTAssertFalse(AppModel.savedBool(key, default: true, defaults))
        defaults.set("YES", forKey: key)
        XCTAssertTrue(AppModel.savedBool(key, default: false, defaults))
        defaults.set(false, forKey: key)
        XCTAssertFalse(AppModel.savedBool(key, default: true, defaults))
    }

    /// The switch set off and the lock choice set to press-press are what the next launch reads. Nothing here says how
    /// the switch starts, so it holds in the AssistOff plan too, where `-assist NO` pins the switch off for every
    /// launch. A model can also be given both settings, which saves nothing.
    func testTheSettingsAreKeptAcrossLaunches() throws {
        let model = AppModel(start: .p4, liveLink: false)
        // On first, so that turning it off is a change, and saved, whatever the switch started as.
        model.assistOn = true
        model.assistOn = false
        model.lockChoice = .pressPress
        let saved = try XCTUnwrap(
            Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) })
        XCTAssertEqual(saved[AppModel.assistKey] as? Bool, false, "saved in the app's own settings")
        XCTAssertEqual(saved[AppModel.lockChoiceKey] as? String, "pressPress", "saved as its raw value")
        let next = AppModel(start: .p4, liveLink: false)
        XCTAssertFalse(next.assistOn)
        XCTAssertEqual(next.lockChoice, .pressPress)

        let given = AppModel(start: .p4, liveLink: false, assistOn: true, lockChoice: .holdThenSlide)
        XCTAssertTrue(given.assistOn)
        XCTAssertEqual(given.lockChoice, .holdThenSlide)
        let after = AppModel(start: .p4, liveLink: false)
        XCTAssertFalse(after.assistOn, "giving them saves nothing")
        XCTAssertEqual(after.lockChoice, .pressPress, "giving them saves nothing")
    }

    /// Settings offers lock only for a robot that allows it, which says how long a latched follow may run. With the
    /// master switch off the row is still offered, disabled, so the choice stays in view.
    func testTheLockRowIsOfferedOnlyWhenTheProfileAllowsLock() {
        for on in [true, false] {
            let simulator = AppModel(start: .p4, liveLink: false, assistOn: on, lockChoice: .off)
            XCTAssertNotNil(simulator.profile.assist.lock)
            XCTAssertTrue(simulator.offersLock, "the simulator's robot allows lock, switch \(on)")

            var noAids = RobotProfile.so101Simulator
            noAids.assist = .none
            let other = AppModel(start: .p4, liveLink: false, profile: noAids, assistOn: on, lockChoice: .pressPress)
            XCTAssertFalse(other.offersLock, "a robot that allows no aids, switch \(on)")
            XCTAssertNil(other.assist.lock, "and no lock is in force, whatever was chosen")
        }
    }

    /// Like the mode, neither setting changes while anything is engaged: the change is refused with "Let go first."
    func testASettingsChangeWhileEngagedIsRefused() {
        let model = AppModel(
            start: .p4, pose: { TestPose.portrait }, liveLink: false, inputClock: { 10 }, assistOn: true,
            lockChoice: .off)
        model.controlMode = .screenTurns
        model.connect()
        model.keyEvent(.upper, down: true)
        XCTAssertTrue(model.session.state.armMoving)
        model.assistOn = false
        XCTAssertTrue(model.assistOn)
        XCTAssertEqual(model.cueLog.last?.event, .refused(.letGoFirst))
        model.lockChoice = .pressPress
        XCTAssertEqual(model.lockChoice, .off)
        XCTAssertEqual(model.controller.arbiter.assist, model.assist)
        XCTAssertTrue(model.session.state.armMoving, "a refused change ends no hold")
        model.keyEvent(.upper, down: false)
        XCTAssertFalse(model.session.state.armMoving)
        model.assistOn = false
        XCTAssertFalse(model.assistOn, "once let go of, it changes")
        model.lockChoice = .pressPress
        XCTAssertEqual(model.lockChoice, .pressPress, "once let go of, it changes")
    }

    /// The input rules always hold the configuration the settings resolve to, from launch on.
    func testEverySetterHandsTheConfigurationToTheController() {
        let model = AppModel(start: .p4, liveLink: false, assistOn: true, lockChoice: .off)
        XCTAssertEqual(model.controller.arbiter.assist, model.assist)
        XCTAssertEqual(model.assist.goTo, model.profile.assist.goTo)
        XCTAssertNil(model.assist.lock)
        model.lockChoice = .pressPress
        XCTAssertEqual(model.assist.lock, LockRule(variant: .pressPress, timeLimitS: 30))
        XCTAssertEqual(model.controller.arbiter.assist, model.assist)
        model.lockChoice = .holdThenSlide
        XCTAssertEqual(model.controller.arbiter.assist.lock?.variant, .holdThenSlide)
        model.assistOn = false
        XCTAssertEqual(model.assist, .off)
        XCTAssertEqual(model.controller.arbiter.assist, .off)
        model.assistOn = true
        XCTAssertEqual(model.controller.arbiter.assist, model.assist)
        XCTAssertNotEqual(model.assist, .off)
        XCTAssertEqual(AppModel(start: .p4, liveLink: false, assistOn: false).controller.arbiter.assist, .off)
    }

    /// Comparing rounds with and without the aids needs to know when each was on.
    func testTheDeveloperLogRecordsEverySwitchChange() {
        let model = AppModel(start: .p4, liveLink: false, assistOn: true, lockChoice: .off)
        model.assistOn = false
        XCTAssertTrue(model.debugLog.last?.hasSuffix("assist: off") == true, "\(model.debugLog)")
        model.assistOn = true
        XCTAssertTrue(model.debugLog.last?.hasSuffix("assist: on") == true, "\(model.debugLog)")
        model.lockChoice = .pressPress
        XCTAssertTrue(model.debugLog.last?.hasSuffix("assist: lock pressPress") == true, "\(model.debugLog)")
        let count = model.debugLog.count
        model.lockChoice = .pressPress
        XCTAssertEqual(model.debugLog.count, count, "no change, no line")
    }

    /// The switch changes nothing the input rules are told about the moment, beyond the arm tap-to-go needs: with it
    /// off they are told no arm and no panel, as in version 1.0.1.
    func testOffLeavesTheFactsAsOneZeroOne() {
        let model = AppModel(start: .p4, pose: { TestPose.portrait }, liveLink: false, assistOn: true)
        model.connect()
        let on = model.inputFacts()
        model.assistOn = false
        XCTAssertEqual(model.inputFacts(), on)
        model.lockChoice = .pressPress
        XCTAssertEqual(model.inputFacts(), on)

        // The arm measured and the panel reported: off, the rules are told neither, and nothing else changes.
        let live = liveModel(assistOn: true)
        live.taskAid = true
        live.guidePanelChanged(Self.panel)
        var onFacts = live.inputFacts()
        XCTAssertNotNil(onFacts.arm, "on, the measured arm is told")
        XCTAssertNotNil(onFacts.goPanel, "on, the panel drawn is told")
        live.assistOn = false
        let offFacts = live.inputFacts()
        XCTAssertNil(offFacts.arm, "off, no arm")
        XCTAssertNil(offFacts.goPanel, "off, no panel")
        onFacts.arm = nil
        onFacts.goPanel = nil
        XCTAssertEqual(offFacts, onFacts)
    }

    /// With tap-to-go allowed the input rules are told where the arm was last measured: the pinch point of the newest
    /// position reported, how old it is, and whether the link is pausing the hold. The panel the screen reports is
    /// kept and told while the guide is drawn. A robot that allows no tap-to-go is told no arm.
    func testTheFactsCarryTheMeasuredArmWhenTapToGoIsAllowed() throws {
        UserDefaults.standard.set(ControlMode.buttons.rawValue, forKey: AppModel.controlModeKey)
        let model = liveModel(assistOn: true)
        XCTAssertEqual(model.controlMode, .screenTurns, "the phone-guide fixture does not inherit saved buttons mode")
        XCTAssertNotNil(model.assist.goTo)
        clock += 40
        var arm = try XCTUnwrap(model.inputFacts().arm)
        let estimated = model.profile.pinchPoint(
            gripper: SIMD3<Float>(SIMD3<Double>(0.02, -0.14, 0.16)), tool: nil, flexDeg: nil, rollDeg: nil)
        XCTAssertEqual(arm.pinch, SIMD3<Double>(estimated.point), "the gripper point plus the tool offset")
        XCTAssertEqual(arm.ageS, 0.04, accuracy: 1e-9)
        XCTAssertFalse(arm.holdPaused)
        transport.server(
            "state",
            ["estop": false, "gripper": "open", "ee_pos": [0.02, -0.14, 0.16], "tool_pos": [0.03, -0.17, 0.08]])
        arm = try XCTUnwrap(model.inputFacts().arm)
        XCTAssertEqual(arm.pinch, SIMD3<Double>(SIMD3<Float>(SIMD3<Double>(0.03, -0.17, 0.08))), "the tool point")
        XCTAssertEqual(arm.ageS, 0, accuracy: 1e-9, "measured just now")

        // The jaws close and are let go of, so the arm's start waits behind them: the link pauses the hold.
        model.send(.gripperStart(.closed))
        clock += 20
        model.send(.gripperEnd)
        model.send(.holdArmStart)
        XCTAssertTrue(model.session.state.armMoving)
        XCTAssertTrue(model.link.holdPaused)
        XCTAssertEqual(model.inputFacts().arm?.holdPaused, true)
        model.send(.holdArmEnd)

        model.taskAid = true
        model.guidePanelChanged(Self.panel)
        XCTAssertEqual(model.guidePanelRect, Self.panel, "the panel the screen reports is kept")
        XCTAssertEqual(model.inputFacts().goPanel?.rect, Self.panel, "and told to the input rules")
        model.guidePanelChanged(nil)
        XCTAssertNil(model.guidePanelRect)
        XCTAssertNil(model.inputFacts().goPanel, "no longer drawn")

        var noTaps = RobotProfile.so101Simulator
        noTaps.assist.goTo = nil
        XCTAssertNil(liveModel(profile: noTaps, assistOn: true).inputFacts().arm, "a robot without tap-to-go")
    }

    /// A move follows how the pinch point turns about the gripper link only from a reading that reported the pinch
    /// point. The input rules are told the gripper link of the same state as the pinch point, and whether the server
    /// reported the pinch point there: a state with a tool point did; one without, or with one that is no usable point,
    /// did not, and its pinch point is the gripper link plus the profile's tool offset. With the switch off they are
    /// told no arm, as in version 1.0.1.
    func testTheFactsSayWhetherThePinchPointWasReportedBesideTheGripperLink() throws {
        let model = liveModel(assistOn: true)
        func estimate(_ gripper: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3<Double>(
                model.profile.pinchPoint(gripper: SIMD3<Float>(gripper), tool: nil, flexDeg: nil, rollDeg: nil).point)
        }
        func assertGripper(_ arm: ArmFix, _ gripper: SIMD3<Double>, _ what: String, line: UInt = #line) {
            XCTAssertLessThan(
                simd_distance(arm.gripper ?? SIMD3(repeating: .infinity), gripper), 1e-12,
                "\(what): the gripper link of that state", line: line)
        }
        var arm = try XCTUnwrap(model.inputFacts().arm)
        XCTAssertFalse(arm.pinchReported, "no tool point")
        assertGripper(arm, SIMD3(0.02, -0.14, 0.16), "no tool point")
        XCTAssertEqual(arm.pinch, estimate(SIMD3(0.02, -0.14, 0.16)), "no tool point")

        transport.server(
            "state",
            ["estop": false, "gripper": "open", "ee_pos": [0.021, -0.141, 0.161], "tool_pos": [0.03, -0.17, 0.08]])
        arm = try XCTUnwrap(model.inputFacts().arm)
        XCTAssertTrue(arm.pinchReported, "a tool point")
        assertGripper(arm, SIMD3(0.021, -0.141, 0.161), "a tool point")
        XCTAssertEqual(arm.pinch, SIMD3<Double>(SIMD3<Float>(SIMD3<Double>(0.03, -0.17, 0.08))), "a tool point")

        // A tool point no `Float` can hold cannot be drawn or moved to: it counts as not reported.
        transport.server(
            "state",
            ["estop": false, "gripper": "open", "ee_pos": [0.022, -0.142, 0.162], "tool_pos": [1e39, -0.17, 0.08]])
        arm = try XCTUnwrap(model.inputFacts().arm)
        XCTAssertFalse(arm.pinchReported, "a tool point that is no usable point")
        assertGripper(arm, SIMD3(0.022, -0.142, 0.162), "a tool point that is no usable point")
        XCTAssertEqual(arm.pinch, estimate(SIMD3(0.022, -0.142, 0.162)), "a tool point that is no usable point")

        model.assistOn = false
        XCTAssertNil(model.inputFacts().arm, "off, no arm")
    }

    /// The panel reaches the input rules only while the guide is drawn: a phone mode, the task aid on, an arm reading
    /// and the view from above reported. It is then the reported rectangle with the projection, the work box and the
    /// table of the picture drawn in it, so a tap asks for the place drawn under the finger.
    func testThePanelReachesTheRulesOnlyWhileTheGuideIsDrawn() throws {
        let model = liveModel(assistOn: true)
        model.controlMode = .screenTurns
        model.taskAid = true
        XCTAssertNil(model.inputFacts().goPanel, "no view reported")
        model.guidePanelChanged(Self.panel)
        let picture = try XCTUnwrap(model.operating.guide)
        let drawn = GoPanel(
            rect: Self.panel, projection: picture.projection, boxLow: picture.workBoxLow, boxHigh: picture.workBoxHigh,
            tableHeight: Double(model.profile.tableHeight))
        XCTAssertEqual(model.inputFacts().goPanel, drawn)
        model.taskAid = false
        XCTAssertNil(model.inputFacts().goPanel, "the task aid off draws no guide")
        model.taskAid = true
        model.controlMode = .buttons
        XCTAssertNil(model.inputFacts().goPanel, "buttons mode draws no guide")
        model.controlMode = .keyTurns
        XCTAssertEqual(model.inputFacts().goPanel, drawn, "scheme B draws it")

        let practice = AppModel(start: .p4, pose: { TestPose.portrait }, liveLink: false, assistOn: true)
        practice.connect()
        practice.guidePanelChanged(Self.panel)
        XCTAssertNil(practice.inputFacts().goPanel, "practice draws no guide")
    }
}
