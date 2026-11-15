import TeleopCore
import XCTest
@testable import Teleop

/// A follow or a move nobody holds on the operating screen. "Locked on" and "Going" sit where "Moving" sits: under the
/// stop, the link, the camera and a take just saved, above a refusal, and catching up as moving does; a hold someone
/// holds is still "Moving". Their words say how they stop, in the moving colour, in both languages, and the scheme's
/// hints, whose touches would stop them, are hidden. The app shows a follow from the press that latched it until the
/// press that ends it, and the guide is told where a move is headed.
final class OperatingRulesAssistTests: XCTestCase {
    private var savedLanguage = L10n.language
    private var savedMode: String?

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.language
        L10n.language = .en
        savedMode = UserDefaults.standard.string(forKey: AppModel.controlModeKey)
    }

    /// Both of the aids' settings are removed, never put back: a launch argument shadows the saved value, so a value
    /// read here and written back could be the argument's, saved for good. The model here is given the aids and saves
    /// nothing; this keeps it so if a test ever sets them.
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppModel.assistKey)
        UserDefaults.standard.removeObject(forKey: AppModel.lockChoiceKey)
        UserDefaults.standard.set(savedMode, forKey: AppModel.controlModeKey)
        L10n.language = savedLanguage
        super.tearDown()
    }

    private func connected(_ change: (inout OperatingFacts) -> Void = { _ in }) -> OperatingFacts {
        var facts = OperatingFacts()
        facts.connected = true
        facts.nowMs = 10_000
        change(&facts)
        return facts
    }

    func testLockedSitsWhereMovingSits() {
        let latched = connected {
            $0.engaged = .translation
            $0.loose = .latched(since: 3)
        }
        XCTAssertEqual(OperatingRules.state(latched), .locked(catchingUp: false))
        var catchingUp = latched
        catchingUp.catchingUp = true
        XCTAssertEqual(OperatingRules.state(catchingUp), .locked(catchingUp: true))
        var held = latched
        held.loose = nil
        XCTAssertEqual(OperatingRules.state(held), .moving(catchingUp: false), "a hold someone holds")

        var everything = latched
        everything.emergencyStop = true
        everything.cameraStopped = true
        everything.lastRefusal = (.noLink, 9_900)
        everything.lastSaved = (3, 9_900)
        everything.serverSaving = true
        everything.commandsBlocked = true
        XCTAssertEqual(OperatingRules.state(everything), .stopped(cause: nil), "the stop wins over everything")
        everything.emergencyStop = false
        everything.connected = false
        XCTAssertEqual(OperatingRules.state(everything), .notConnected(reason: nil), "then the link")
        everything.connected = true
        XCTAssertEqual(OperatingRules.state(everything), .trackingLost, "then the camera")
        everything.cameraStopped = false
        XCTAssertEqual(OperatingRules.state(everything), .saved(count: 3), "then a take just saved")
        everything.lastSaved = nil
        XCTAssertEqual(OperatingRules.state(everything), .locked(catchingUp: false), "then the follow")
        everything.engaged = nil
        everything.loose = nil
        XCTAssertEqual(OperatingRules.state(everything), .refused(.noLink), "then a refusal just heard")
    }

    /// "Locked on" in the colour of a moving arm, and the one thing to know: how to stop it, since there is no key
    /// to let go of.
    func testTheLockedWordsSayHowItStops() throws {
        let fixture = try XCTUnwrap(OperatingFixtures.all["locked"])
        let moving = try XCTUnwrap(OperatingFixtures.all["moving"])
        let look = OperatingWords.look(fixture)
        XCTAssertEqual(look.word, "Locked on")
        XCTAssertEqual(look.details, ["Any key or touch stops it"])
        XCTAssertEqual(look.colour, OperatingWords.look(moving).colour, "the moving colour")
        var catchingUp = fixture
        catchingUp.state = .locked(catchingUp: true)
        XCTAssertEqual(OperatingWords.look(catchingUp).details, ["Any key or touch stops it", "Catching up"])
        L10n.language = .zhHant
        XCTAssertEqual(OperatingWords.look(fixture).word, "已鎖定")
        XCTAssertEqual(OperatingWords.look(catchingUp).details, ["按任一鍵或觸碰即停", "手臂跟上中"])
    }

    /// A move to a point tapped on the guide sits where moving sits as well, and catches up as moving does.
    func testGoingSitsWhereMovingSits() {
        let going = connected {
            $0.engaged = .translation
            $0.loose = .going(target: SIMD3(0.07, -0.15, 0.09), since: 3)
        }
        XCTAssertEqual(OperatingRules.state(going), .going(catchingUp: false))
        var catchingUp = going
        catchingUp.catchingUp = true
        XCTAssertEqual(OperatingRules.state(catchingUp), .going(catchingUp: true))

        var everything = going
        everything.emergencyStop = true
        everything.cameraStopped = true
        everything.lastRefusal = (.noLink, 9_900)
        everything.lastSaved = (3, 9_900)
        everything.commandsBlocked = true
        XCTAssertEqual(OperatingRules.state(everything), .stopped(cause: nil), "the stop wins over everything")
        everything.emergencyStop = false
        everything.connected = false
        XCTAssertEqual(OperatingRules.state(everything), .notConnected(reason: nil), "then the link")
        everything.connected = true
        XCTAssertEqual(OperatingRules.state(everything), .trackingLost, "then the camera")
        everything.cameraStopped = false
        XCTAssertEqual(OperatingRules.state(everything), .saved(count: 3), "then a take just saved")
        everything.lastSaved = nil
        XCTAssertEqual(OperatingRules.state(everything), .going(catchingUp: false), "then the move")
        everything.engaged = nil
        everything.loose = nil
        XCTAssertEqual(OperatingRules.state(everything), .refused(.noLink), "then a refusal just heard")
    }

    /// "Going" in the colour of a moving arm, and how it stops, in both languages.
    func testTheGoingWordsSayHowItStops() throws {
        let fixture = try XCTUnwrap(OperatingFixtures.all["going"])
        let moving = try XCTUnwrap(OperatingFixtures.all["moving"])
        XCTAssertEqual(OperatingWords.look(fixture).word, "Going")
        XCTAssertEqual(OperatingWords.look(fixture).details, ["Any key or touch stops it"])
        XCTAssertEqual(OperatingWords.look(fixture).colour, OperatingWords.look(moving).colour, "the moving colour")
        var catchingUp = fixture
        catchingUp.state = .going(catchingUp: true)
        XCTAssertEqual(OperatingWords.look(catchingUp).details, ["Any key or touch stops it", "Catching up"])
        L10n.language = .zhHant
        XCTAssertEqual(OperatingWords.look(fixture).word, "前往中")
        XCTAssertEqual(OperatingWords.look(fixture).details, ["按任一鍵或觸碰即停"])
    }

    /// Where the move is headed reaches the guide's reading and changes nothing else in it; without a move the
    /// reading is version 1.0.1's.
    func testTheGoTargetReachesTheReading() throws {
        let state = ServerState(activity: .poseTracking, endEffector: SIMD3(0.02, -0.14, 0.16))
        let profile = RobotProfile.so101Simulator
        let plain = try XCTUnwrap(OperatingRules.arm(state, commanded: nil, gripping: false, profile: profile))
        XCTAssertNil(plain.goTarget)
        let target = SIMD3<Float>(0.07, -0.15, 0.09)
        var going = try XCTUnwrap(
            OperatingRules.arm(state, commanded: nil, gripping: false, profile: profile, goTarget: target))
        XCTAssertEqual(going.goTarget, target)
        going.goTarget = nil
        XCTAssertEqual(going, plain)
    }

    /// The scheme's hints name touches that move the jaws or the wrist; a follow or a move nobody holds is stopped by
    /// those touches instead, so the hints are hidden then. Moving, a hold someone holds, shows them as in version
    /// 1.0.1, and so does every other state.
    func testTheSchemeHintsAreHiddenWhileLockedOrGoing() {
        XCTAssertTrue(OperatingRules.hidesSchemeHints(.locked(catchingUp: false)))
        XCTAssertTrue(OperatingRules.hidesSchemeHints(.locked(catchingUp: true)))
        XCTAssertTrue(OperatingRules.hidesSchemeHints(.going(catchingUp: false)))
        XCTAssertTrue(OperatingRules.hidesSchemeHints(.going(catchingUp: true)))
        let shown: [OperatingState] = [
            .ready, .moving(catchingUp: false), .moving(catchingUp: true), .opening, .closing(gripped: false),
            .refused(.posture), .wait(.saving), .slowLink(ms: 450),
        ]
        for state in shown { XCTAssertFalse(OperatingRules.hidesSchemeHints(state), "\(state)") }
        for name in ["locked", "going"] {
            XCTAssertTrue(OperatingRules.hidesSchemeHints(OperatingFixtures.all[name]!.state), name)
        }
    }

    /// In practice, with lock chosen as a press then a press: the screen says "Locked on" from the latching press,
    /// through its release, until the next press stops the arm. With no lock the same press is "Moving" and its
    /// release stops it.
    func testTheScreenShowsTheFollowFromThePressThatLatchesItToThePressThatEndsIt() {
        var clock = 10.0
        let model = AppModel(
            start: .p4, haptics: NoHaptics(), sounds: SpySounds(), speech: SpySpeech(), pose: { TestPose.portrait },
            liveLink: false, inputClock: { clock }, assistOn: true, lockChoice: .pressPress)
        model.controlMode = .screenTurns
        model.connect()
        XCTAssertEqual(model.operating.state, .ready)
        clock += 0.1
        model.keyEvent(.upper, down: true)
        guard case .latched? = model.controller.loose else {
            return XCTFail("not latched: \(String(describing: model.controller.loose))")
        }
        XCTAssertEqual(model.operating.state, .locked(catchingUp: false))
        clock += 0.1
        model.keyEvent(.upper, down: false)
        XCTAssertEqual(model.operating.state, .locked(catchingUp: false), "the release does not stop it")
        clock += 0.5
        model.keyEvent(.upper, down: true)
        XCTAssertNil(model.controller.loose)
        XCTAssertEqual(model.operating.state, .ready)
        clock += 0.1
        model.keyEvent(.upper, down: false)

        model.lockChoice = .off
        clock += 0.5
        model.keyEvent(.upper, down: true)
        XCTAssertNil(model.controller.loose, "a hold someone holds")
        XCTAssertEqual(model.operating.state, .moving(catchingUp: false))
        clock += 0.1
        model.keyEvent(.upper, down: false)
        XCTAssertEqual(model.operating.state, .ready)
    }
}
