import simd
import TeleopCore
import XCTest
@testable import Teleop

private final class MarkTestTransport: LinkTransport {
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

/// The camera mark, the app's belief that the camera is stopped, follows the camera. ARKit's interruption report sets
/// it. Its end report clears it, as in version 1.0.1. When the app itself runs the camera again after the mark was set,
/// the first frame stamped after that run and after the newest interruption report proves the camera runs and clears
/// the mark too, feeding the input rules nothing. The input rules are told each run and each camera stop as a new
/// attitude frame, and get no sample stamped before it. ARKit does not run in the iPhone simulator, so its reports, its
/// frames and the tracker's run are given here as `PoseTracker` would give them.
final class CameraMarkTests: XCTestCase {
    private var control: MarkTestTransport?
    private var clock = 10_000
    private var model: AppModel!
    private var savedMode: String?
    private var savedTaskAid: Any?
    /// The camera pose the model reads, as `PoseTracker.current` holds it: the newest frame's while it was tracked.
    private var camera: simd_float4x4? = TestPose.portrait
    /// The cue log's length at the point a test counts what was heard from.
    private var heardFrom = 0

    /// The phone tipped 60 degrees toward lying flat, screen up.
    private let tipped = TestPose.portrait(turned: -60, about: SIMD3(1, 0, 0))
    /// The same phone, held the same way, as a new run of the tracking sees it: the new world frame's heading is 18
    /// degrees round, and with the phone tipped toward flat much of that reads as a turn about the screen's normal.
    private var tippedInANewFrame: simd_float4x4 {
        simd_float4x4(simd_quatf(angle: 18 * .pi / 180, axis: SIMD3(0, 1, 0))) * tipped
    }

    /// A thumb on the control surface, outside the guide's view from above.
    private let thumb = SIMD2<Double>(100, 600)

    override func setUp() {
        super.setUp()
        savedMode = UserDefaults.standard.string(forKey: AppModel.controlModeKey)
        savedTaskAid = UserDefaults.standard.object(forKey: AppModel.taskAidKey)
    }

    /// The aids' settings are given to each model, never saved; both keys are removed, never put back, as every test
    /// that could touch them does.
    override func tearDown() {
        UserDefaults.standard.set(savedMode, forKey: AppModel.controlModeKey)
        UserDefaults.standard.set(savedTaskAid, forKey: AppModel.taskAidKey)
        UserDefaults.standard.removeObject(forKey: AppModel.assistKey)
        UserDefaults.standard.removeObject(forKey: AppModel.lockChoiceKey)
        model = nil
        control = nil
        super.tearDown()
    }

    private var seconds: TimeInterval { Double(clock) / 1000 }

    /// A model on a real server with the link up, on the operating screen, with the aids' master switch as given and no
    /// lock, so the upper key is a plain held move.
    private func bringUp(assistOn: Bool = true, mode: ControlMode = .screenTurns) {
        clock = 10_000
        camera = TestPose.portrait
        control = nil
        model = AppModel(
            start: .p4, haptics: NoHaptics(), sounds: SpySounds(), speech: SpySpeech(),
            pose: { [unowned self] in camera }, liveLink: true,
            makeTransport: { [unowned self] _ in
                let made = MarkTestTransport()
                control = made
                return made
            },
            makeObserverTransport: { _ in MarkTestTransport() },
            nowMs: { [unowned self] in clock },
            inputClock: { [unowned self] in seconds },
            assistOn: assistOn, lockChoice: .off
        )
        model.controlMode = mode
        connect()
        frame(TestPose.portrait)
    }

    private func connect() {
        model.session.state.serverAddress = "100.64.0.1:8765"
        model.connect()
        control?.server("welcome")
        control?.server("state", ["estop": false, "gripper": "open"])
        XCTAssertTrue(model.session.state.connected)
    }

    /// A frame ARKit hands over now, stamped `age` seconds ago, with its camera pose, or nil without normal tracking.
    private func frame(_ pose: simd_float4x4?, stampedAgo age: TimeInterval = 0) {
        camera = pose
        model.poseFrame(pose, at: seconds - age)
    }

    /// The tracker ran the camera session now, as `PoseTracker` reports it.
    private func trackerRan() {
        PoseTracker.shared.onRun?(seconds)
    }

    private func touch(_ id: Int, _ phase: TouchSample.Phase, at p: SIMD2<Double>) {
        model.touch(TouchSample(id: id, phase: phase, x: p.x, y: p.y, majorRadius: 8), at: seconds)
    }

    private func tick(_ ms: Int) {
        clock += ms
        model.controller.tick()
    }

    private var heard: [CueKey] { model.cueLog.dropFirst(heardFrom).map(\.event) }

    // MARK: The mark

    /// As on the phone: the camera is interrupted as the app leaves, the link drops while it is away, the Connect
    /// screen pauses the camera while it is still interrupted, so ARKit never reports the end; the link comes back on
    /// the operating screen and the app runs the camera again. Its first frame, not yet normally tracked, clears the
    /// mark.
    func testTheMarkClearsAtTheFirstFrameAfterTheAppRanTheCamera() {
        bringUp()
        clock += 100
        model.controller.cameraInterrupted(true)
        XCTAssertTrue(model.controller.isCameraStopped)
        clock += 5000
        control?.onClose?()
        XCTAssertEqual(model.session.route, .s1)
        clock += 2000
        connect()
        XCTAssertEqual(model.session.route, .p5)
        clock += 20
        trackerRan()
        clock += 400
        frame(nil)
        XCTAssertFalse(
            model.controller.isCameraStopped,
            "the camera stayed marked stopped after the app ran it and its frames arrived, with no end report")
        for _ in 0..<5 {
            clock += 33
            frame(TestPose.portrait)
        }
        tick(1100)
        XCTAssertEqual(model.operating.state, .ready)
        heardFrom = model.cueLog.count
        model.keyEvent(.upper, down: true)
        XCTAssertTrue(model.session.state.armMoving, "the upper key starts the arm: \(heard)")
        XCTAssertEqual(heard, [])
    }

    /// A run proves nothing until a frame from it arrives: the camera may still be stopped. Neither the run nor the app
    /// becoming active clears the mark.
    func testARunWithoutAFrameLeavesTheMark() {
        bringUp()
        clock += 100
        model.controller.cameraInterrupted(true)
        clock += 100
        model.activeChanged(false)
        clock += 3000
        model.activeChanged(true)
        clock += 20
        trackerRan()
        tick(1500)
        XCTAssertTrue(model.controller.isCameraStopped, "a run proves nothing until a frame from it arrives")
        XCTAssertEqual(model.operating.state, .trackingLost)
        heardFrom = model.cueLog.count
        model.keyEvent(.upper, down: true)
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertEqual(heard, [.refused(.notTracking)], "Can't track the phone.")
    }

    /// With no run of the app's own since the mark was set, frames prove nothing: one handed over late may be from
    /// before the interruption. ARKit's end report clears the mark, and the input rules are told the app is active
    /// again, as in version 1.0.1: a jaw hold that began while the camera was stopped ends with it.
    func testFramesWithoutARunLeaveTheMarkToTheEndReport() {
        bringUp()
        clock += 100
        model.controller.cameraInterrupted(true)
        for _ in 0..<10 {
            clock += 33
            frame(TestPose.portrait)
        }
        XCTAssertTrue(model.controller.isCameraStopped)
        clock += 100
        model.keyEvent(.lower, down: true)
        XCTAssertEqual(model.session.state.gripperMoving, .closed, "the jaws close while the camera is stopped")
        clock += 300
        model.controller.cameraInterrupted(false)
        XCTAssertFalse(model.controller.isCameraStopped)
        XCTAssertNil(model.session.state.gripperMoving, "the end report ends the hold, as in 1.0.1")
        clock += 100
        model.keyEvent(.lower, down: false)
    }

    func testAFrameStampedBeforeTheRunLeavesTheMark() {
        bringUp()
        clock += 100
        model.controller.cameraInterrupted(true)
        clock += 2000
        trackerRan()
        clock += 100
        frame(TestPose.portrait, stampedAgo: 0.15)
        XCTAssertTrue(model.controller.isCameraStopped, "a frame captured before the run proves nothing")
        clock += 33
        frame(TestPose.portrait)
        XCTAssertFalse(model.controller.isCameraStopped)
    }

    func testAFrameStampedBeforeALaterInterruptionLeavesTheMark() {
        bringUp()
        clock += 100
        model.controller.cameraInterrupted(true)
        clock += 2000
        trackerRan()
        clock += 200
        // A second report comes before any frame of the run reached the app.
        model.controller.cameraInterrupted(true)
        clock += 50
        frame(TestPose.portrait, stampedAgo: 0.1)
        XCTAssertTrue(model.controller.isCameraStopped, "a frame captured before the newest report proves nothing")
        clock += 33
        frame(TestPose.portrait)
        XCTAssertTrue(model.controller.isCameraStopped, "the camera was stopped again since the app ran it")
        clock += 500
        model.controller.cameraInterrupted(false)
        XCTAssertFalse(model.controller.isCameraStopped)
    }

    /// Clearing the mark at a frame feeds the input rules nothing. A jaw hold that began between the run and its first
    /// frame keeps closing until its key's release, and a thumb that came down then is still a thumb. A tap that began
    /// then is not judged: its view of the guide is taken at touch-down, and the view is withheld while the camera is
    /// marked stopped.
    func testAJawHoldAndAThumbBegunAfterTheRunSpanTheFirstFrame() throws {
        bringUp()
        clock += 100
        model.controller.cameraInterrupted(true)
        clock += 3000
        trackerRan()
        heardFrom = model.cueLog.count
        clock += 300
        model.keyEvent(.lower, down: true)
        XCTAssertEqual(model.session.state.gripperMoving, .closed)
        clock += 100
        frame(nil)
        XCTAssertFalse(model.controller.isCameraStopped)
        for _ in 0..<6 {
            clock += 33
            frame(TestPose.portrait)
            model.controller.tick()
        }
        XCTAssertEqual(model.session.state.gripperMoving, .closed, "the jaws keep closing")
        clock += 300
        model.keyEvent(.lower, down: false)
        XCTAssertNil(model.session.state.gripperMoving, "until the key's release")
        XCTAssertEqual(heard, [], "no stop and no cue")

        // A thumb down between the next run and its first frame opens the jaws by a slide up after it.
        clock += 500
        model.controller.cameraInterrupted(true)
        clock += 3000
        trackerRan()
        heardFrom = model.cueLog.count
        clock += 300
        touch(1, .began, at: thumb)
        clock += 50
        frame(nil)
        XCTAssertFalse(model.controller.isCameraStopped)
        for step in 1...12 {
            clock += 16
            frame(TestPose.portrait)
            touch(1, .moved, at: thumb - SIMD2(0, 6.4 * Double(step)))
        }
        XCTAssertEqual(model.session.state.gripperMoving, .open, "the thumb's slide up opens the jaws: \(heard)")
        clock += 100
        touch(1, .ended, at: thumb - SIMD2(0, 6.4 * 12))
        XCTAssertNil(model.session.state.gripperMoving)
        XCTAssertEqual(heard, [])

        // A tap on the guide's view from above that began before the first frame starts nothing and tells nothing.
        model.taskAid = true
        let pinch = SIMD3<Double>(0.03, -0.18, 0.09)
        let gripper = pinch - SIMD3<Double>(model.profile.toolOffset)
        control?.server("state", ["estop": false, "gripper": "open", "ee_pos": [gripper.x, gripper.y, gripper.z]])
        model.guidePanelChanged(SurfaceLayout.Rect(x: 118, y: 262, width: 166, height: 166))
        let panel = try XCTUnwrap(model.inputFacts().goPanel)
        let point = panel.point(over: SIMD3(0.07, -0.15, 0.09))
        clock += 500
        model.controller.cameraInterrupted(true)
        clock += 3000
        trackerRan()
        heardFrom = model.cueLog.count
        clock += 300
        touch(2, .began, at: point)
        clock += 30
        frame(TestPose.portrait)
        XCTAssertFalse(model.controller.isCameraStopped)
        clock += 30
        touch(2, .ended, at: point)
        XCTAssertNil(model.controller.arbiter.engagement, "no move")
        XCTAssertFalse(model.session.state.armMoving)
        XCTAssertEqual(heard, [], "nothing is told")
        XCTAssertNotNil(model.inputFacts().goPanel, "the view reaches the rules again")
    }

    func testTheEndReportStillClearsTheMark() {
        bringUp()
        clock += 100
        model.controller.cameraInterrupted(true)
        XCTAssertEqual(model.operating.state, .trackingLost)
        clock += 2000
        model.controller.cameraInterrupted(false)
        XCTAssertFalse(model.controller.isCameraStopped)
        tick(1100)
        XCTAssertEqual(model.operating.state, .ready)
        model.keyEvent(.upper, down: true)
        XCTAssertTrue(model.session.state.armMoving)
    }

    func testTheMarkClearsWithTheSwitchOffToo() {
        bringUp(assistOn: false)
        XCTAssertEqual(model.assist, .off)
        clock += 100
        model.controller.cameraInterrupted(true)
        clock += 3000
        model.send(.openSettings)
        model.send(.back)
        XCTAssertEqual(model.session.route, .p4)
        clock += 20
        trackerRan()
        clock += 300
        frame(TestPose.portrait)
        XCTAssertFalse(model.controller.isCameraStopped)
        tick(1100)
        XCTAssertEqual(model.operating.state, .ready)
        model.keyEvent(.upper, down: true)
        XCTAssertTrue(model.session.state.armMoving)
    }

    /// In buttons mode the tracking is paused on purpose and no frame comes, so the operating screen does not show the
    /// mark there. Back in a phone mode it shows until the next run's first frame.
    func testInButtonsModeTheScreenIgnoresTheMark() {
        bringUp(mode: .buttons)
        clock += 100
        model.controller.cameraInterrupted(true)
        tick(100)
        XCTAssertTrue(model.controller.isCameraStopped)
        XCTAssertEqual(model.operating.state, .ready, "buttons mode does not say the camera stopped")
        model.controlMode = .screenTurns
        XCTAssertEqual(model.operating.state, .trackingLost)
        clock += 20
        trackerRan()
        clock += 300
        frame(TestPose.portrait)
        XCTAssertFalse(model.controller.isCameraStopped)
        XCTAssertEqual(model.operating.state, .ready)
    }

    // MARK: The attitude across a run

    /// As on the phone after a trip to Settings: the tracking runs again with the phone tipped toward flat, the thumb
    /// comes down before any tracked frame, and the first one arrives inside the thumb's palm window. Measured against
    /// the attitude from before the run, it would read as a turn of about 16 degrees and start the wrist.
    func testTheFirstTouchAfterTheRunReadsNoTurn() {
        for assistOn in [true, false] {
            bringUp(assistOn: assistOn)
            clock += 33
            frame(tipped)
            clock += 1000
            model.send(.openSettings)
            clock += 3000
            model.send(.back)
            XCTAssertEqual(model.session.route, .p4)
            clock += 20
            trackerRan()
            heardFrom = model.cueLog.count
            clock += 400
            touch(1, .began, at: thumb)
            clock += 50
            frame(tippedInANewFrame)
            for _ in 0..<6 {
                clock += 33
                frame(tippedInANewFrame)
                model.controller.tick()
            }
            XCTAssertFalse(model.session.state.wristMoving, "aids \(assistOn): the wrist turned for a turn never made")
            XCTAssertNil(model.controller.arbiter.engagement, "aids \(assistOn)")
            XCTAssertEqual(heard, [], "aids \(assistOn)")
            clock += 100
            touch(1, .ended, at: thumb)
            XCTAssertEqual(heard, [], "aids \(assistOn)")
        }
    }

    /// A frame captured before the run but handed over after it is in the old world frame. It never reaches the rules,
    /// so a thumb that came down meanwhile anchors at the first sample of the new frame, not at that one.
    func testASampleStampedBeforeTheRunIsNotGivenToTheRules() {
        bringUp()
        clock += 33
        frame(tipped)
        clock += 1000
        model.send(.openSettings)
        clock += 3000
        model.send(.back)
        clock += 20
        trackerRan()
        heardFrom = model.cueLog.count
        clock += 400
        touch(1, .began, at: thumb)
        clock += 20
        frame(tipped, stampedAgo: 0.5)
        clock += 30
        frame(tippedInANewFrame)
        for _ in 0..<6 {
            clock += 33
            frame(tippedInANewFrame)
            model.controller.tick()
        }
        XCTAssertFalse(model.session.state.wristMoving, "a sample from before the run anchored the thumb")
        XCTAssertNil(model.controller.arbiter.engagement)
        XCTAssertEqual(heard, [])
    }

    /// The camera stop ends a wrist hold in its own step, as in version 1.0.1; the new attitude frame reaches the rules
    /// in a step after it, with nothing left to end, so the hold is stopped once.
    func testTheCountMovesAfterTheCameraStopHasEndedTheHolds() {
        bringUp()
        touch(1, .began, at: thumb)
        for step in 1...10 {
            clock += 33
            frame(TestPose.portrait(turned: Float(3 * step), about: SIMD3(0, 0, 1)))
            model.controller.tick()
        }
        XCTAssertTrue(model.session.state.wristMoving, "the thumb turns the wrist")
        let frameBefore = model.controller.attitudeFrame
        model.clearLog()
        heardFrom = model.cueLog.count
        clock += 33
        model.controller.cameraInterrupted(true)
        XCTAssertFalse(model.session.state.wristMoving)
        XCTAssertNil(model.controller.arbiter.engagement)
        XCTAssertEqual(model.controller.attitudeFrame, frameBefore + 1)
        XCTAssertEqual(model.debugLog.filter { $0.hasSuffix("→ wristEnd") }.count, 1, "\(model.debugLog)")
        XCTAssertEqual(heard, [], "the camera stop's own cues for a held hold: none from the rules")
        XCTAssertEqual(model.controller.arbiter.held[.touch(1)], .dead, "the thumb stays dead until lifted")
    }
}
