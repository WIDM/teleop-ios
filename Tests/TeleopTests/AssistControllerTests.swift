import simd
import TeleopCore
import XCTest
@testable import Teleop

private final class ReasonTestTransport: LinkTransport {
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

/// When every hold ends, the controller tells the input rules why, as far as the app knows it, and a follow nobody
/// holds is heard ending for that reason: a stop or a lost link has played its own cue, a refused start has played its
/// refusal, and the slow link, leaving the operating screen, leaving the app and the camera stopping are named. A
/// reason nobody gives is heard as "Stopped here." alone, never taken for one already told. With a hold tied to an
/// input the reason changes nothing anyone hears, so these run on a follow latched by a press of the upper key, chosen
/// through the model. Each start is carried as the kind the rules recorded: a tap's start as a move to a point.
final class AssistControllerTests: XCTestCase {
    private var control: ReasonTestTransport?
    private var clock = 10_000
    private var model: AppModel!
    private var savedMode: String?
    private var savedTaskAid: Any?
    /// The phone is held turned 60 degrees on its side, which refuses a phone hold for posture.
    private var tilted = false
    /// The cue log's length when the follow latched.
    private var mark = 0

    override func setUp() {
        super.setUp()
        savedMode = UserDefaults.standard.string(forKey: AppModel.controlModeKey)
        savedTaskAid = UserDefaults.standard.object(forKey: AppModel.taskAidKey)
    }

    /// Both of the aids' settings are removed, never put back: a launch argument shadows the saved value, so a value
    /// read here and written back could be the argument's, saved for good. The models here are given the aids and
    /// save nothing; this keeps it so if a test ever sets them. The task aid, which draws the guide a tap needs, is put
    /// back as it was.
    override func tearDown() {
        UserDefaults.standard.set(savedMode, forKey: AppModel.controlModeKey)
        UserDefaults.standard.set(savedTaskAid, forKey: AppModel.taskAidKey)
        UserDefaults.standard.removeObject(forKey: AppModel.assistKey)
        UserDefaults.standard.removeObject(forKey: AppModel.lockChoiceKey)
        model = nil
        control = nil
        super.tearDown()
    }

    /// A model on a real server, in scheme A, with lock variant 1, whose link is not open yet; with the aids' master
    /// switch off when `assistOn` is false.
    private func makeModel(speech: SpySpeech = SpySpeech(), assistOn: Bool = true) {
        clock = 10_000
        control = nil
        tilted = false
        model = AppModel(
            start: .p4, haptics: NoHaptics(), sounds: SpySounds(), speech: speech,
            pose: { [unowned self] in
                tilted ? TestPose.portrait(turned: 60, about: SIMD3(0, 0, 1)) : TestPose.portrait
            },
            liveLink: true,
            makeTransport: { [unowned self] _ in
                let made = ReasonTestTransport()
                control = made
                return made
            },
            makeObserverTransport: { _ in ReasonTestTransport() },
            nowMs: { [unowned self] in clock },
            inputClock: { [unowned self] in Double(clock) / 1000 },
            assistOn: assistOn, lockChoice: .pressPress
        )
        model.controlMode = .screenTurns
        mark = model.cueLog.count
    }

    /// Standby with the link up.
    private func bringUp(speech: SpySpeech = SpySpeech(), assistOn: Bool = true) {
        makeModel(speech: speech, assistOn: assistOn)
        model.session.state.serverAddress = "100.64.0.1:8765"
        model.connect()
        control?.server("welcome")
        control?.server("state", ["estop": false, "gripper": "open"])
        XCTAssertTrue(model.session.state.connected)
    }

    /// The upper key's press starts the follow, and its release leaves it running.
    private func latchTheArm(line: UInt = #line) {
        clock += 100
        model.keyEvent(.upper, down: true)
        clock += 100
        model.keyEvent(.upper, down: false)
        XCTAssertTrue(model.session.state.armMoving, line: line)
        guard case .latched? = model.controller.arbiter.engagement else {
            return XCTFail("not latched: \(String(describing: model.controller.arbiter.engagement))", line: line)
        }
        XCTAssertEqual(model.cueLog.last?.event, .drive(.latched), line: line)
        mark = model.cueLog.count
    }

    /// The endings of a follow heard since it latched.
    private var endingsHeard: [DriveCue] {
        model.cueLog.dropFirst(mark).compactMap { entry -> DriveCue? in
            guard case .drive(let cue) = entry.event, cue != .latched else { return nil }
            return cue
        }
    }

    private func heardSinceTheLatch(_ event: CueKey) -> Bool {
        model.cueLog.dropFirst(mark).contains { $0.event == event }
    }

    /// The follow ended, the session's hold with it, and exactly this ending was heard: none when someone else has
    /// told it.
    private func assertEnded(hearing ending: DriveEnd?, _ message: String, line: UInt = #line) {
        XCTAssertEqual(endingsHeard, ending.map { [.ended($0)] } ?? [], message, line: line)
        XCTAssertNil(model.controller.arbiter.engagement, message, line: line)
        XCTAssertFalse(model.session.state.armMoving, message, line: line)
    }

    func testSessionChangedNamesTheReason() {
        bringUp()
        latchTheArm()
        model.send(.stop)
        assertEnded(hearing: nil, "STOP: its ALARM has played")
        XCTAssertTrue(
            model.cueLog.dropFirst(mark).contains {
                if case .emergencyStop = $0.event { return true }
                return false
            }, "\(model.cueLog)")

        bringUp()
        latchTheArm()
        control?.onClose?()
        assertEnded(hearing: nil, "a lost link: its sound and words have played")
        XCTAssertTrue(heardSinceTheLatch(.linkLost(holdEngaged: true)))

        // The session is connected but no link is open, so the link cannot start the hold the session took.
        makeModel()
        model.session.state.markConnected()
        clock += 100
        model.keyEvent(.upper, down: true)
        assertEnded(hearing: nil, "a refused start: its refusal has played")
        XCTAssertTrue(heardSinceTheLatch(.refused(.noLink)))

        bringUp()
        latchTheArm()
        model.send(.linkLatency(ms: 500))
        XCTAssertTrue(model.session.state.armMoving, "one slow sample is not a slow link")
        XCTAssertEqual(endingsHeard, [])
        model.send(.linkLatency(ms: 500))
        XCTAssertTrue(model.session.state.commandsBlocked)
        assertEnded(hearing: .slowLink, "a slow link")

        bringUp()
        latchTheArm()
        model.send(.openSettings)
        XCTAssertEqual(model.session.route, .s6)
        assertEnded(hearing: .leftScreen, "leaving the operating screen")

        bringUp()
        latchTheArm()
        model.send(.holdArmEnd)
        assertEnded(hearing: .unnamed, "the session's hold ended and nobody said why")
    }

    func testLeavingTheAppAndTheCameraNameTheirReasons() {
        bringUp()
        latchTheArm()
        model.activeChanged(false)
        assertEnded(hearing: .appLeft, "the app left the active state")
        model.activeChanged(true)
        XCTAssertEqual(endingsHeard, [.ended(.appLeft)], "coming back ends nothing more")

        bringUp()
        latchTheArm()
        model.controller.cameraInterrupted(true)
        assertEnded(hearing: .cameraStopped, "the camera stopped")
    }

    /// A press whose start the link could not carry latches nothing the operator hears: the refusal is the one cue,
    /// and the latch cue that came with the start is not played.
    func testTheLatchCueIsSkippedWhenTheStartWasRefused() {
        // The session is connected but no link is open, so the link cannot start the hold the session took.
        makeModel()
        model.session.state.markConnected()
        clock += 100
        model.keyEvent(.upper, down: true)
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertNil(model.controller.arbiter.engagement)
        XCTAssertEqual(model.cueLog.dropFirst(mark).map(\.event), [.refused(.noLink)])
        XCTAssertFalse(model.link.holdIsLoose)
        clock += 100
        model.keyEvent(.upper, down: false)
        XCTAssertEqual(model.cueLog.dropFirst(mark).map(\.event), [.refused(.noLink)], "the release adds nothing")
    }

    /// A historical saved result keeps the voice occupied while a follow starts. STOP or link loss must cancel
    /// the queued latch announcement; otherwise it plays once the voice is free.
    func testALockedOnWaitingForTheVoiceIsNotSaidAfterStopOrLinkLoss() {
        for ending in ["STOP", "a lost link", "neither"] {
            let speech = SpySpeech()
            speech.holds = true
            bringUp(speech: speech)
            XCTAssertEqual(speech.spoken, ["Controls available."], ending)
            speech.finish()
            speech.spoken = []
            model.raise(.takeSaved(count: 1))
            XCTAssertEqual(speech.spoken, ["Saved. 1."], ending)
            latchTheArm()
            XCTAssertEqual(speech.spoken, ["Saved. 1."], "\(ending): Locked on. waits for the voice")
            switch ending {
            case "STOP": model.send(.stop)
            case "a lost link": control?.onClose?()
            default: break
            }
            if ending != "neither" {
                XCTAssertEqual(
                    speech.spoken.count, 2, "\(ending): told at once, interrupting the saved result: \(speech.spoken)")
            }
            for _ in 0..<4 {
                clock += 1000
                speech.finish()
            }
            XCTAssertEqual(
                speech.spoken.contains("Locked on."), ending == "neither", "\(ending): \(speech.spoken)")
        }
    }

    /// The operator's own ending is carried to the model as such.
    func testAPressThatEndsTheFollowIsHeardAsStoppedByYou() {
        bringUp()
        latchTheArm()
        clock += 500
        model.keyEvent(.lower, down: true)
        XCTAssertEqual(endingsHeard, [.stoppedByYou])
        XCTAssertNil(model.controller.arbiter.engagement)
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertNil(model.session.state.gripperMoving, "the press that ended it moved nothing")
        clock += 100
        model.keyEvent(.lower, down: false)
        XCTAssertEqual(endingsHeard, [.stoppedByYou])
    }

    /// A tap on the guide's view from above starts a move to that point, which the rules record as such, and the
    /// controller carries it as a move: the session and the link run it on the pad's path, so with the phone held on
    /// its side, which refuses a phone hold, it starts with no refusal, and nobody holds it.
    func testAGoingStartIsCarriedAsAGoingHold() throws {
        bringUp()
        model.taskAid = true
        // The arm's pinch point at the travel height, and the guide's view from above where the reference phone draws
        // it.
        let pinch = SIMD3<Double>(0.03, -0.18, 0.09)
        let gripper = pinch - SIMD3<Double>(model.profile.toolOffset)
        control?.server("state", ["estop": false, "gripper": "open", "ee_pos": [gripper.x, gripper.y, gripper.z]])
        model.guidePanelChanged(SurfaceLayout.Rect(x: 118, y: 262, width: 166, height: 166))
        tilted = true
        XCTAssertEqual(model.inputFacts().translationRefusal, .posture, "a phone hold would be refused")
        let panel = try XCTUnwrap(model.inputFacts().goPanel)
        let point = panel.point(over: SIMD3(0.07, -0.15, 0.09))
        mark = model.cueLog.count
        clock += 100
        model.touch(TouchSample(id: 1, phase: .began, x: point.x, y: point.y, majorRadius: 8), at: Double(clock) / 1000)
        clock += 50
        model.touch(TouchSample(id: 1, phase: .ended, x: point.x, y: point.y, majorRadius: 8), at: Double(clock) / 1000)
        XCTAssertEqual(model.controller.arbiter.startsThisCall, [.going], "the rules recorded a move")
        guard case .going? = model.controller.arbiter.engagement else {
            return XCTFail("no move: \(String(describing: model.controller.arbiter.engagement))")
        }
        XCTAssertTrue(model.session.state.armMoving, "the session runs it")
        XCTAssertTrue(model.link.holdIsLoose, "nobody holds it")
        XCTAssertEqual(model.cueLog.dropFirst(mark).map(\.event), [], "no refusal")
        XCTAssertEqual(model.operating.state, .going(catchingUp: false))
    }

    /// While the camera is stopped the guide is still drawn, but no key reaches the app and the screen says the camera
    /// stopped, so a move started then could be neither seen nor stopped with a key, and the camera's return would end
    /// it as if the app had been left. The input rules are given no panel meanwhile: a tap on the guide's view from
    /// above starts nothing and tells nothing, and the camera's return tells no ending. Once it is back the panel
    /// reaches the rules again.
    func testATapWhileTheCameraIsStoppedStartsNothing() throws {
        bringUp()
        model.taskAid = true
        let pinch = SIMD3<Double>(0.03, -0.18, 0.09)
        let gripper = pinch - SIMD3<Double>(model.profile.toolOffset)
        control?.server("state", ["estop": false, "gripper": "open", "ee_pos": [gripper.x, gripper.y, gripper.z]])
        model.guidePanelChanged(SurfaceLayout.Rect(x: 118, y: 262, width: 166, height: 166))
        let panel = try XCTUnwrap(model.inputFacts().goPanel)
        let point = panel.point(over: SIMD3(0.07, -0.15, 0.09))
        model.controller.cameraInterrupted(true)
        XCTAssertNil(model.inputFacts().goPanel, "no panel reaches the rules while the camera is stopped")
        mark = model.cueLog.count
        clock += 100
        model.touch(TouchSample(id: 1, phase: .began, x: point.x, y: point.y, majorRadius: 8), at: Double(clock) / 1000)
        clock += 50
        model.touch(TouchSample(id: 1, phase: .ended, x: point.x, y: point.y, majorRadius: 8), at: Double(clock) / 1000)
        XCTAssertEqual(model.controller.arbiter.startsThisCall, [], "nothing starts")
        XCTAssertNil(model.controller.arbiter.engagement, "no move")
        XCTAssertFalse(model.session.state.armMoving, "the arm stays")
        XCTAssertEqual(model.cueLog.dropFirst(mark).map(\.event), [], "nothing is told")

        clock += 1000
        model.controller.cameraInterrupted(false)
        XCTAssertFalse(endingsHeard.contains(.ended(.appLeft)), "the app was not left")
        XCTAssertEqual(model.cueLog.dropFirst(mark).map(\.event), [], "the camera's return tells no ending")
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertNotNil(model.inputFacts().goPanel, "the panel reaches the rules again")
    }

    /// With the aids off, a stopped camera refuses what it refused in version 1.0.1 and nothing more: it is no reason
    /// to refuse every start. A press of the lower key still closes the jaws, with no refusal, and its release stops
    /// them; a thumb held on the surface while the phone turns, a wrist hold, needs the camera's tracking and is
    /// refused "No tracking.", and its lift adds nothing.
    func testWithTheAidsOffAStoppedCameraStillLetsTheJawsRun() throws {
        bringUp(assistOn: false)
        model.surfaceChanged(width: 402, height: 874, safeTop: 62, safeBottom: 34)
        let surface = try XCTUnwrap(model.operating.layout).controlSurface
        clock += 33
        model.poseFrame(TestPose.portrait, at: Double(clock) / 1000)
        model.controller.cameraInterrupted(true)
        mark = model.cueLog.count

        clock += 500
        model.keyEvent(.lower, down: true)
        XCTAssertEqual(model.session.state.gripperMoving, .closed, "the jaws close")
        XCTAssertEqual(model.cueLog.dropFirst(mark).map(\.event), [], "no refusal")
        clock += 300
        model.controller.tick()
        model.keyEvent(.lower, down: false)
        XCTAssertNil(model.session.state.gripperMoving, "the release stops them")
        XCTAssertEqual(model.cueLog.dropFirst(mark).map(\.event), [])

        // The thumb rests a fifth of a second, then the phone turns 30 degrees on its side, 3 degrees a frame.
        let thumb = (x: surface.x + 0.3 * surface.width, y: surface.y + 0.8 * surface.height)
        clock += 500
        model.touch(TouchSample(id: 1, phase: .began, x: thumb.x, y: thumb.y, majorRadius: 8), at: Double(clock) / 1000)
        for _ in 0..<6 {
            clock += 33
            model.controller.tick()
        }
        XCTAssertEqual(model.cueLog.dropFirst(mark).map(\.event), [], "a thumb at rest starts nothing")
        for step in 1...10 {
            clock += 33
            let turned = TestPose.portrait(turned: Float(3 * step), about: SIMD3(0, 0, 1))
            model.poseFrame(turned, at: Double(clock) / 1000)
            model.controller.tick()
        }
        XCTAssertFalse(model.session.state.wristMoving, "no wrist hold")
        XCTAssertNil(model.controller.arbiter.engagement)
        XCTAssertEqual(model.cueLog.dropFirst(mark).map(\.event), [.refused(.notTracking)], "No tracking.")
        clock += 33
        model.touch(TouchSample(id: 1, phase: .ended, x: thumb.x, y: thumb.y, majorRadius: 8), at: Double(clock) / 1000)
        XCTAssertEqual(model.cueLog.dropFirst(mark).map(\.event), [.refused(.notTracking)], "the lift adds nothing")
        XCTAssertNil(model.session.state.gripperMoving)
    }
}
