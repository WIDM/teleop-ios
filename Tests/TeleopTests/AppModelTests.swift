import TeleopCore
import XCTest
@testable import Teleop

/// What the haptic player was asked to do.
enum Felt: Equatable {
    case play(Haptic)
    case stop
}

final class SpyHaptics: HapticsPlaying {
    var felt: [Felt] = []
    func play(_ haptic: Haptic) { felt.append(.play(haptic)) }
    func stop() { felt.append(.stop) }
}

final class SpySpeech: SpeechPlaying {
    var onFinished: ((Int) -> Void)?
    var spoken: [String] = []
    /// True: each utterance goes on until `finish`. False: it ends as soon as it starts.
    var holds = false
    /// Utterances still being spoken, oldest first; `finish` ends the oldest.
    var speaking: [Int] = []

    func speak(_ text: String, language: String, interrupt: Bool, id: Int) {
        if interrupt { speaking = [] }
        spoken.append(text)
        if holds { speaking.append(id) } else { onFinished?(id) }
    }

    func finish() {
        guard !speaking.isEmpty else { return }
        onFinished?(speaking.removeFirst())
    }
}

final class SpySounds: SoundPlaying {
    var played: [Sound] = []
    func play(_ sound: Sound) { played.append(sound) }
}

final class AppModelTests: XCTestCase {
    private var savedLanguage = L10n.language

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.language
        L10n.language = .en
    }

    override func tearDown() {
        L10n.language = savedLanguage
        super.tearDown()
    }

    /// STOP rattles (ALARM) and says why; releasing it stops the pattern and says the robot is ready.
    func testStopRattlesAndReleaseStopsIt() {
        let spy = SpyHaptics(), speech = SpySpeech()
        let model = AppModel(start: .p4, haptics: spy, speech: speech, liveLink: false)
        model.send(.stop)
        XCTAssertEqual(spy.felt, [.play(.alarm)])
        XCTAssertEqual(speech.spoken.last, "Emergency stop. You pressed stop. Hold the top edge to reset.")
        model.send(.releaseStop)
        XCTAssertEqual(spy.felt, [.play(.alarm), .stop])
        XCTAssertEqual(model.session.route, .p4)
        speech.finish()
        XCTAssertEqual(speech.spoken.last, "Ready.")
    }

    func testBlockedGripperIsRefusedWithThreeTicksAndTheReason() {
        let spy = SpyHaptics(), speech = SpySpeech()
        let model = AppModel(start: .p4, haptics: spy, speech: speech)
        model.session.state.markConnected()
        model.session.state.commandsBlocked = true
        model.send(.gripperStart(.closed))
        XCTAssertEqual(spy.felt, [.play(.no)])
        XCTAssertEqual(speech.spoken, ["Slow link."])
    }

    func testTheDemoHoldIsLiveAtOnce() {
        let spy = SpyHaptics()
        var clock = 1000
        let model = AppModel(start: .p4, haptics: spy, liveLink: false, nowMs: { clock })
        model.send(.holdArmStart)
        XCTAssertEqual(spy.felt, [.play(.go)])
        model.send(.holdArmEnd)
        clock += 500
        model.send(.gripperStart(.closed))
        XCTAssertEqual(spy.felt, [.play(.go), .play(.go)], "the gripper press's own buzz is replaced by GO")
    }

    func testAPressWhileStoppedIsRefusedWithItsReason() {
        let spy = SpyHaptics(), speech = SpySpeech()
        var clock = 1000
        let model = AppModel(start: .p4, haptics: spy, speech: speech, liveLink: false, nowMs: { clock })
        model.send(.stop)
        clock += 100
        model.send(.holdArmStart)
        XCTAssertEqual(spy.felt, [.play(.alarm)], "the rattle is not cut short by three ticks")
        clock += 1500
        model.send(.holdArmStart)
        XCTAssertEqual(spy.felt.last, .play(.no))
        XCTAssertEqual(speech.spoken.last, "Stopped.")
        XCTAssertFalse(model.session.state.armMoving)
    }

    /// A reset needs everything let go: while the arm is held it is refused and the hold goes on.
    func testAResetWhileSomethingIsHeldIsRefused() {
        let spy = SpyHaptics(), speech = SpySpeech()
        let model = AppModel(start: .p4, haptics: spy, speech: speech, liveLink: false)
        model.send(.holdArmStart)
        model.send(.resetScene)
        XCTAssertTrue(model.session.state.armMoving)
        XCTAssertEqual(spy.felt, [.play(.go), .play(.no)])
        XCTAssertEqual(speech.spoken, ["Let go first."])
        model.send(.holdArmEnd)
        model.send(.resetScene)
        XCTAssertEqual(spy.felt.count, 2)
    }

    /// Other parts raise their own cues through the model, as the input does.
    func testACueRaisedFromOutsidePlays() {
        let spy = SpyHaptics(), speech = SpySpeech()
        let model = AppModel(start: .p4, haptics: spy, speech: speech, liveLink: false)
        model.raise(.limit(.alreadyGripping))
        XCTAssertEqual(spy.felt, [.play(.end)])
        XCTAssertEqual(speech.spoken, ["Already gripping."])
        XCTAssertEqual(model.cueLog.last?.event, .limit(.alreadyGripping))
    }

    func testTheStopStateOffersReleaseOnTheDemo() {
        let model = AppModel(start: .p4, haptics: SpyHaptics(), liveLink: false)
        XCTAssertEqual(model.stopExits.exits, [.resetScene, .releaseKeepScene])
        XCTAssertEqual(model.recorder, .unknown)
        XCTAssertNil(model.serverState)
        XCTAssertFalse(model.gripping)
    }

    func testAnArmHoldStartsAndStopsTheArm() {
        let model = AppModel(start: .p4, haptics: SpyHaptics(), liveLink: false)
        model.session.state.markConnected()
        model.send(.holdArmStart)
        XCTAssertTrue(model.session.state.armMoving)
        model.send(.holdArmEnd)
        XCTAssertFalse(model.session.state.armMoving)
    }

    func testSettingsSurviveLeavingS6() {
        let model = AppModel(start: .p4, haptics: SpyHaptics())
        model.send(.openSettings)
        model.session.state.setSmoothing(0.9)
        model.send(.settingsDone)
        model.send(.openSettings)
        XCTAssertEqual(model.session.state.smoothing, 0.9)
    }

    func testS1ConnectReturnsToP5() {
        let model = AppModel(start: .s1, haptics: SpyHaptics(), liveLink: false)
        model.send(.connect)
        XCTAssertEqual(model.session.route, .p5)
        XCTAssertTrue(model.session.state.connected)
    }

    func testStartRoute() {
        let defaults = UserDefaults(suiteName: "AppModelTests")!
        defaults.removePersistentDomain(forName: "AppModelTests")
        XCTAssertEqual(AppModel.startRoute(from: defaults), .s2, "a fresh install opens on permissions")
        defaults.set(true, forKey: AppModel.firstRunDoneKey)
        XCTAssertEqual(AppModel.startRoute(from: defaults), .p4, "every later launch opens on standby")
        defaults.set("s1_connect", forKey: "startRoute")
        XCTAssertEqual(AppModel.startRoute(from: defaults), .s1)
        defaults.set("nope", forKey: "startRoute")
        XCTAssertEqual(AppModel.startRoute(from: defaults), .p4)
    }

    func testTheUnitTestHostDoesNotOpenTheSavedServer() {
        XCTAssertFalse(AppModel.opensSavedServerAtLaunch(), "this process is the unit-test host")
        XCTAssertTrue(AppModel.opensSavedServerAtLaunch(environment: [:]))
    }

    func testReachingStandbyEndsTheFirstRun() {
        let saved = UserDefaults.standard.object(forKey: AppModel.firstRunDoneKey)
        defer { UserDefaults.standard.set(saved, forKey: AppModel.firstRunDoneKey) }
        let ways: [String: [TeleopAction]] = [
            "skip": [.tutorialSkip],
            "finish": [.tutorialNext(step: 1), .tutorialNext(step: 2), .tutorialNext(step: 3)],
            "STOP during the tutorial, then release": [.stop, .releaseStop],
        ]
        for (way, actions) in ways {
            UserDefaults.standard.removeObject(forKey: AppModel.firstRunDoneKey)
            let model = AppModel(start: .s2, haptics: SpyHaptics())
            model.send(.permissionsContinue)
            XCTAssertEqual(model.session.route, .t1)
            for action in actions.dropLast() { model.send(action) }
            XCTAssertFalse(UserDefaults.standard.bool(forKey: AppModel.firstRunDoneKey), way)
            model.send(actions.last!)
            XCTAssertEqual(model.session.route, .p4, way)
            XCTAssertTrue(UserDefaults.standard.bool(forKey: AppModel.firstRunDoneKey), way)
        }
    }
}
