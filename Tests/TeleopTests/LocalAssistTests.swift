import simd
import TeleopCore
import TeleopServerHost
import TeleopServerModel
import XCTest
@testable import Teleop

/// Lock with the scripted hand's raw inputs, through the app's model and link, against the server model on a local
/// socket in real time. A press then a press: the arm follows the phone with no key held until the next press. A hold
/// then a slide: a thumb slid up the glass while the upper key is held latches the follow, in scheme A, in scheme B's
/// centre band and on a half slowly, and a thumb that does not slide changes nothing. Every ending of a latched follow
/// stops the server's hold and is heard exactly once. A tap on the guide's view from above sends the jaws to that point
/// at the travel height, in both schemes, and "Arrived." is heard once.
final class LocalAssistTests: XCTestCase {
    private var server: LocalTeleopServer!
    private var hand: ScriptedOperator!
    private var savedTaskAid: Any?
    private var model: AppModel { hand.model }

    /// The task aid is put back as it was. Both of the aids' settings are removed, never put back: a launch argument
    /// shadows the saved value, so a value read here and written back could be the argument's, saved for good.
    override func tearDown() {
        hand?.finish()
        hand = nil
        server?.stop()
        server = nil
        UserDefaults.standard.set(savedTaskAid, forKey: AppModel.taskAidKey)
        UserDefaults.standard.removeObject(forKey: AppModel.assistKey)
        UserDefaults.standard.removeObject(forKey: AppModel.lockChoiceKey)
        super.tearDown()
    }

    /// - Parameter path: the network path under both of the app's sockets; none when nil.
    private func start(_ mode: ControlMode, lock: LockChoice, path: StallingPath? = nil) throws {
        server = LocalTeleopServer(config: .s4Simulator(stepsPerSecond: 60, reportsToolPoint: true))
        try server.start()
        hand = ScriptedOperator(
            address: server.address, mode: mode, smoothing: 0.3, pace: 0.3, makeTransport: path.map { $0.transport })
        savedTaskAid = UserDefaults.standard.object(forKey: AppModel.taskAidKey)
        hand.model.taskAid = true
        // Through the setters, which set the model's own value whatever a launch argument says.
        hand.model.assistOn = true
        hand.model.lockChoice = lock
        XCTAssertTrue(hand.connect(within: 4), "could not connect to the local server")
        hand.pump(1)
    }

    private var arm: SIMD3<Double> { server.inspect { $0.world.arm } }
    private var serverHolds: Bool { server.inspect { $0.state["ik"]?.stringValue } == "pose_tracking" }

    private func heard(_ key: CueKey, since mark: Int = 0) -> Bool {
        model.cueLog.dropFirst(mark).contains { $0.event == key }
    }

    /// The ending cues heard since `mark`: a move's endings, the alarm, link loss during a hold, a success's narration.
    private func endings(since mark: Int) -> [CueKey] {
        model.cueLog.dropFirst(mark).map(\.event).filter(LooseEndingHeardTests.isEndingCue)
    }

    /// The follow latched: the session's hold runs, the screen says so, the latch was heard, and no NO with it.
    private func assertLatched(_ what: String, since mark: Int, line: UInt = #line) {
        XCTAssertTrue(model.session.state.armMoving, "\(what): following", line: line)
        guard case .locked = model.operating.state else {
            return XCTFail("\(what): the screen shows \(model.operating.state)", line: line)
        }
        XCTAssertTrue(heard(.drive(.latched), since: mark), "\(what): the latch was heard", line: line)
        XCTAssertFalse(heard(.refused(.deadInput), since: mark), "\(what): no NO", line: line)
        XCTAssertTrue(hand.wait(2, until: { serverHolds }), "\(what): the server's hold runs", line: line)
    }

    /// The follow ended, the server's hold with it, and exactly `ending` was the one ending cue heard.
    private func assertEnded(_ what: String, hearing ending: CueKey, since mark: Int, line: UInt = #line) {
        XCTAssertFalse(model.session.state.armMoving, "\(what): the session's hold ended", line: line)
        XCTAssertNil(model.controller.loose, "\(what): nothing follows", line: line)
        XCTAssertTrue(hand.wait(2, until: { !serverHolds }), "\(what): the server's hold ended", line: line)
        XCTAssertEqual(endings(since: mark), [ending], what, line: line)
    }

    // MARK: A press then a press

    private func pressPressFollowsWithNoKeyHeld(_ mode: ControlMode) throws {
        try start(mode, lock: .pressPress)
        var mark = model.cueLog.count
        hand.lockPressPress()
        assertLatched("\(mode)", since: mark)
        let before = arm
        // 4 cm right, with no key held. Right is −X in the robot base.
        hand.move(to: SIMD3(0.04, 0, 0), in: 1)
        hand.pump(3)
        XCTAssertEqual(before.x - arm.x, 0.04, accuracy: 0.01, "\(mode): the arm followed the phone")
        mark = model.cueLog.count
        hand.press(.upper)
        XCTAssertFalse(model.session.state.armMoving, "\(mode): the next press stops it at once")
        hand.release(.upper)
        assertEnded("\(mode)", hearing: .drive(.stoppedByYou), since: mark)
        // The key that ended it was dead only until it was let go of.
        hand.pump(0.5)
        mark = model.cueLog.count
        hand.lockPressPress()
        assertLatched("\(mode), again", since: mark)
        hand.press(.upper)
        hand.release(.upper)
    }

    func testAPressThenAPressFollowsWithNoKeyHeldSchemeA() throws {
        try pressPressFollowsWithNoKeyHeld(.screenTurns)
    }

    func testAPressThenAPressFollowsWithNoKeyHeldSchemeB() throws {
        try pressPressFollowsWithNoKeyHeld(.keyTurns)
    }

    // MARK: A hold then a slide

    /// The thumb rests in the middle of the glass in scheme A: the slide latches with no NO, the follow outlives the
    /// key, and the lower key then stops it without closing the jaws.
    func testAThumbSlidUpLatchesInSchemeA() throws {
        try start(.screenTurns, lock: .holdThenSlide)
        var mark = model.cueLog.count
        hand.lockHoldSlide(at: hand.surfaceCentre, millimetres: 12, seconds: 0.25)
        assertLatched("scheme A", since: mark)
        hand.pump(1)
        XCTAssertTrue(model.session.state.armMoving, "still following with nothing held")
        mark = model.cueLog.count
        hand.press(.lower)
        assertEnded("the lower key", hearing: .drive(.stoppedByYou), since: mark)
        hand.pump(1)
        XCTAssertNotEqual(server.inspect { $0.state["gripper"]?.stringValue }, "close", "the jaws did not close")
        XCTAssertNil(model.session.state.gripperMoving)
        hand.release(.lower)
    }

    /// Scheme B's centre band, where every touch is dead and silent otherwise: a thumb resting there and slid up
    /// latches.
    func testAThumbSlidUpLatchesInSchemeBsCentreBand() throws {
        try start(.keyTurns, lock: .holdThenSlide)
        XCTAssertEqual(hand.layout.zone(x: hand.surfaceCentre.x, y: hand.surfaceCentre.y), .controlSurface)
        let mark = model.cueLog.count
        hand.lockHoldSlide(at: hand.surfaceCentre, millimetres: 12, seconds: 0.25)
        assertLatched("scheme B, centre band", since: mark)
        hand.press(.upper)
        hand.release(.upper)
    }

    /// On a half of scheme B, 12 mm over half a second runs past the 150 ms dwell: the dwell's NO waits for the slide,
    /// and the latch drops it.
    func testASlowSlideOnAHalfLatchesWithoutItsNO() throws {
        try start(.keyTurns, lock: .holdThenSlide)
        let mark = model.cueLog.count
        hand.lockHoldSlide(at: hand.half(.near), millimetres: 12, seconds: 0.5)
        assertLatched("scheme B, a half, slowly", since: mark)
        hand.press(.upper)
        hand.release(.upper)
    }

    /// A thumb that lands and lifts without sliding, while the upper key holds the arm: the release stops the arm, and
    /// the operator hears what they hear with the aids off. GO is left out of the comparison, since its moment beside
    /// a NO depends on the server's answer.
    private func aThumbThatDoesNotSlideChangesNothing(
        _ mode: ControlMode, at place: (ScriptedOperator) -> SIMD2<Double>
    ) throws -> [CueKey] {
        try start(mode, lock: .holdThenSlide)
        let thumb = place(hand)
        var heardBy: [Bool: [CueKey]] = [:]
        for aids in [false, true] {
            hand.model.assistOn = aids
            hand.pump(0.5)
            let mark = model.cueLog.count
            hand.press(.upper)
            hand.pump(0.5)
            let id = hand.touchDown(x: thumb.x, y: thumb.y)
            hand.pump(1)
            hand.touchUp(id, x: thumb.x, y: thumb.y)
            hand.pump(0.3)
            hand.release(.upper)
            XCTAssertFalse(model.session.state.armMoving, "\(mode), aids \(aids): the release stops it")
            XCTAssertTrue(hand.wait(2, until: { !serverHolds }), "\(mode), aids \(aids): the server's hold ended")
            let heard = model.cueLog.dropFirst(mark).map(\.event)
            XCTAssertEqual(heard.filter { $0 == .holdLive }.count, 1, "\(mode), aids \(aids): GO")
            heardBy[aids] = heard.filter { $0 != .holdLive }
        }
        XCTAssertEqual(heardBy[true], heardBy[false], "\(mode)")
        return heardBy[true] ?? []
    }

    func testAThumbThatDoesNotSlideChangesNothingSchemeA() throws {
        let heard = try aThumbThatDoesNotSlideChangesNothing(.screenTurns, at: { $0.surfaceCentre })
        XCTAssertEqual(heard, [], "a thumb resting on the glass during a hold is silent")
    }

    func testAThumbThatDoesNotSlideChangesNothingSchemeB() throws {
        let heard = try aThumbThatDoesNotSlideChangesNothing(.keyTurns, at: { $0.half(.near) })
        XCTAssertEqual(heard, [.refused(.deadInput)], "on a half, the dwell's NO")
    }

    // MARK: Endings

    /// From a fresh latch each time: a touch on the glass, the top band, the gear, the phone turned past the posture
    /// limit, the app left, the camera stopped, a jump of the hand, and STOP. Each stops the server's hold and is heard
    /// once; the inputs that end it do nothing else.
    func testEveryEndingOfALatchedFollowIsHeardOnce() throws {
        try start(.screenTurns, lock: .pressPress)
        let gear = hand.gear, glass = hand.surfaceCentre, band = hand.topBand
        let endings: [(String, CueKey, () -> Void)] = [
            ("a touch on the glass", .drive(.stoppedByYou), { [unowned self] in touchAndRest(glass) }),
            ("the top band, held as for a reset", .drive(.stoppedByYou), { [unowned self] in touchAndRest(band) }),
            ("a tap on the gear", .drive(.stoppedByYou), { [unowned self] in hand.tap(x: gear.x, y: gear.y) }),
            (
                "the phone turned", .drive(.ended(.posture)),
                { [unowned self] in
                    hand.turnPhone(.turn, to: 50, in: 0.3)
                    _ = hand.wait(1, until: { !model.session.state.armMoving })
                    hand.rotation = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1))
                }
            ),
            (
                "the app left", .drive(.ended(.appLeft)),
                { [unowned self] in
                    model.activeChanged(false)
                    hand.pump(0.3)
                    model.activeChanged(true)
                }
            ),
            (
                "the camera stopped", .drive(.ended(.cameraStopped)),
                {
                    PoseTracker.shared.onInterruption?(true)
                    PoseTracker.shared.onInterruption?(false)
                }
            ),
            (
                "the hand jumped", .drive(.ended(.tooFast)),
                { [unowned self] in
                    hand.position = SIMD3(0.2, 0, 0)
                    _ = hand.wait(1, until: { !model.session.state.armMoving })
                    hand.position = .zero
                }
            ),
        ]
        for (what, ending, cause) in endings {
            hand.pump(0.5)
            var mark = model.cueLog.count
            hand.lockPressPress()
            assertLatched(what, since: mark)
            mark = model.cueLog.count
            cause()
            assertEnded(what, hearing: ending, since: mark)
            hand.pump(0.5)
            XCTAssertNotEqual(model.session.route, .s6, "\(what): Settings not opened")
            XCTAssertEqual(server.inspect { $0.episode }, 0, "\(what): no reset")
        }

        hand.pump(0.5)
        var mark = model.cueLog.count
        hand.lockPressPress()
        assertLatched("STOP", since: mark)
        mark = model.cueLog.count
        hand.tap(x: hand.bottomBand.x, y: hand.bottomBand.y)
        XCTAssertTrue(model.session.state.emergencyStop)
        XCTAssertTrue(hand.wait(2, until: { server.inspect { $0.state["estop"] } == true }), "STOP reached the server")
        assertEnded("STOP", hearing: .emergencyStop(.button, takeDiscarded: false), since: mark)
        XCTAssertFalse(
            model.cueLog.dropFirst(mark).contains {
                if case .drive = $0.event { return true }
                return false
            }, "the alarm alone")
    }

    /// The network path stalls for a second: the server's watchdog ends the hold, and once the path is back the
    /// operator hears it once, as a link hiccup.
    func testAStalledPathEndsALatchedFollowAsALinkHiccup() throws {
        let path = StallingPath()
        try start(.screenTurns, lock: .pressPress, path: path)
        var mark = model.cueLog.count
        hand.lockPressPress()
        assertLatched("before the stall", since: mark)
        hand.pump(1)
        mark = model.cueLog.count
        path.stall()
        _ = hand.wait(1.0, until: { false })
        path.resume()
        XCTAssertTrue(hand.wait(2, until: { !model.session.state.armMoving }), "the server's watchdog ended it")
        assertEnded("a stalled path", hearing: .drive(.ended(.linkHiccup)), since: mark)
        XCTAssertTrue(model.session.state.connected, "the stall cost the hold, not the link")
    }

    // MARK: A tap on the guide

    /// The hand taps the view from above over a point 4 cm to the side of and 3 cm beyond the jaws: the screen says
    /// "Going", the arm goes to the travel height and across, the move ends within the profile's tolerance of the
    /// tapped point at that height, the server's hold ends with it, and "Arrived." is the one ending heard.
    private func aTapGoesThere(_ mode: ControlMode) throws {
        try start(mode, lock: .off)
        hand.reportGuidePanel()
        let goTo = try XCTUnwrap(model.assist.goTo)
        let pinch = try hand.measuredPinch()
        let target = SIMD3(pinch.x + 0.04, pinch.y - 0.03, Double(model.profile.tableHeight) + goTo.travelHeightM)
        let mark = model.cueLog.count
        try hand.tapGuide(over: target)
        guard case .going = model.operating.state else {
            return XCTFail("\(mode): the screen shows \(model.operating.state)")
        }
        XCTAssertTrue(hand.wait(15, until: { !model.session.state.armMoving }), "\(mode): the move ended")
        XCTAssertEqual(endings(since: mark), [.drive(.arrived)], "\(mode)")
        XCTAssertNil(model.controller.loose, "\(mode)")
        XCTAssertTrue(hand.wait(2, until: { !serverHolds }), "\(mode): the server's hold ended")
        let jaws = server.inspect { $0.world.arm + $0.config.toolOffset }
        XCTAssertLessThanOrEqual(
            simd_distance(jaws, target), goTo.arriveToleranceM, "\(mode): the jaws at the tapped point, \(jaws)")
        hand.pump(0.5)
        XCTAssertEqual(endings(since: mark), [.drive(.arrived)], "\(mode): nothing more")
    }

    func testATapOnTheGuideGoesThereSchemeA() throws {
        try aTapGoesThere(.screenTurns)
    }

    func testATapOnTheGuideGoesThereSchemeB() throws {
        try aTapGoesThere(.keyTurns)
    }

    /// A thumb comes down at `point`, rests longer than a reset takes, and lifts: the touch that ends a follow is dead
    /// until it lifts, so it counts nothing down and moves nothing.
    private func touchAndRest(_ point: SIMD2<Double>) {
        let id = hand.touchDown(x: point.x, y: point.y)
        let countdown = hand.wait(2.5, until: { model.operating.resetCountdown != nil })
        XCTAssertFalse(countdown, "no countdown")
        XCTAssertFalse(model.session.state.wristMoving, "no wrist hold")
        XCTAssertNil(model.session.state.gripperMoving, "no jaw hold")
        hand.touchUp(id, x: point.x, y: point.y)
    }
}
