import TeleopCore
import XCTest
@testable import Teleop

/// The aids' settings: the master switch and the lock choice. How they are read at launch, kept across launches,
/// refused while something is engaged, recorded in the developer log and handed to the input rules, and that turning
/// them changes nothing the input rules are told about the moment.
final class AssistModelTests: XCTestCase {
    private var savedMode: String?

    override func setUp() {
        super.setUp()
        savedMode = UserDefaults.standard.string(forKey: AppModel.controlModeKey)
    }

    /// Both of the aids' settings are removed, never put back: a launch argument shadows the saved value, so a value
    /// read here and written back could be the argument's (the AssistOff plan's `-assist NO`), saved for good. The UI
    /// tests and every other test launch with neither saved.
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppModel.assistKey)
        UserDefaults.standard.removeObject(forKey: AppModel.lockChoiceKey)
        UserDefaults.standard.set(savedMode, forKey: AppModel.controlModeKey)
        super.tearDown()
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

    /// The switch changes nothing the input rules are told about the moment.
    func testOffLeavesTheFactsAsOneZeroOne() {
        let model = AppModel(start: .p4, pose: { TestPose.portrait }, liveLink: false, assistOn: true)
        model.connect()
        let on = model.inputFacts()
        model.assistOn = false
        XCTAssertEqual(model.inputFacts(), on)
        model.lockChoice = .pressPress
        XCTAssertEqual(model.inputFacts(), on)
    }
}
