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
/// at the travel height, in both schemes, and "Arrived." is heard once; a tap in the view's margin is refused and
/// starts nothing; a move the server's box cuts short is heard once as stopped short, before any correction when it
/// follows the pinch point the server reports, and after at least one correction and no more than the profile allows
/// when the server reports none; a stalled network path ends a move once as no arm data; an object held in the jaws
/// goes with them; and a touch during a move stops it and then starts nothing while that thumb stays down. One move is
/// one hold for the session and on the wire.
final class LocalAssistTests: XCTestCase {
    private var server: LocalTeleopServer!
    private var hand: ScriptedOperator!
    private var path: StallingPath?
    private var savedTaskAid: Any?
    private var model: AppModel { hand.model }
    /// What the hand has seen of the session's arm hold since `watchTheMove()`: how often it started and ended.
    private var holdStarts = 0
    private var holdEnds = 0
    private var wasMoving = false
    /// The legs the move's command walked, when a test watches them.
    private var legs: CommandLegs?

    /// The task aid is put back as it was. Both of the aids' settings are removed, never put back: a launch argument
    /// shadows the saved value, so a value read here and written back could be the argument's, saved for good.
    override func tearDown() {
        hand?.watch = nil
        hand?.finish()
        hand = nil
        server?.stop()
        server = nil
        path = nil
        legs = nil
        UserDefaults.standard.set(savedTaskAid, forKey: AppModel.taskAidKey)
        UserDefaults.standard.removeObject(forKey: AppModel.assistKey)
        UserDefaults.standard.removeObject(forKey: AppModel.lockChoiceKey)
        super.tearDown()
    }

    /// - Parameters:
    ///   - path: the network path under both of the app's sockets, which also records what the app sends; none when
    ///     nil.
    ///   - serverBox: how far either way of the arm's start the server keeps the arm, metres; the server model's own
    ///     box when nil.
    ///   - reportsPinch: whether the server's state carries the pinch point.
    ///   - transport: both of the app's sockets, in place of `path`'s.
    private func start(
        _ mode: ControlMode, lock: LockChoice, path: StallingPath? = nil, serverBox: Double? = nil,
        reportsPinch: Bool = true, transport: ((URL) -> LinkTransport)? = nil
    ) throws {
        var config = ServerModelConfig.s4Simulator(stepsPerSecond: 60, reportsToolPoint: reportsPinch)
        if let serverBox { config.workspaceHalfSize = serverBox }
        server = LocalTeleopServer(config: config)
        try server.start()
        self.path = path
        hand = ScriptedOperator(
            address: server.address, mode: mode, smoothing: 0.3, pace: 0.3,
            makeTransport: transport ?? path.map { $0.transport })
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

    /// Everything heard since `mark`, in order.
    private func cues(since mark: Int) -> [CueKey] { model.cueLog.dropFirst(mark).map(\.event) }

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

    /// From now on, on every turn of the run loop, counts the session's arm hold starting and ending, and samples the
    /// move's command into `legs` when it is set.
    private func watchTheMove() {
        holdStarts = 0
        holdEnds = 0
        wasMoving = model.session.state.armMoving
        hand.watch = { [unowned self] in
            let moving = model.session.state.armMoving
            if moving != wasMoving {
                if moving { holdStarts += 1 } else { holdEnds += 1 }
                wasMoving = moving
            }
            legs?.sample(model.controller.goOffset())
        }
    }

    /// The type of every message the app sent on its control connection, the first one the path carries.
    private var sentOnTheWire: [String] { path?.sent[1] ?? [] }

    /// One move is one hold: the session's arm hold started once and ended once (a re-sent start stays inside the
    /// link), the wire carried a pose start before any other pose message and ended with a pose stop, and nothing
    /// streamed after that stop.
    private func assertOneHold(_ what: String, wireSince mark: Int, line: UInt = #line) {
        XCTAssertEqual(holdStarts, 1, "\(what): the session's hold started once", line: line)
        XCTAssertEqual(holdEnds, 1, "\(what): and ended once", line: line)
        let wire = Array(sentOnTheWire.dropFirst(mark))
        XCTAssertEqual(wire.first { $0.hasPrefix("pose_") }, "pose_start", "\(what): \(wire)", line: line)
        guard let stop = wire.lastIndex(of: "pose_stop") else {
            return XCTFail("\(what): no pose stop on the wire: \(wire)", line: line)
        }
        let after = wire[stop...].filter { $0 == "pose_update" || $0 == "pose_start" }
        XCTAssertEqual(after, [], "\(what): nothing streamed after the stop", line: line)
    }

    /// The travel height in the robot base frame: every tapped point is sent there.
    private func travelHeight(_ goTo: GoToLimits) -> Double { Double(model.profile.tableHeight) + goTo.travelHeightM }

    /// The hand taps the view from above over a point 4 cm to the side of and 3 cm beyond the jaws: the screen says
    /// "Going", the arm goes to the travel height and across, the move ends within the profile's tolerance of the
    /// tapped point at that height, the server's hold ends with it, and "Arrived." is the one ending heard.
    private func aTapGoesThere(_ mode: ControlMode) throws {
        try start(mode, lock: .off, path: StallingPath())
        hand.reportGuidePanel()
        let goTo = try XCTUnwrap(model.assist.goTo)
        let pinch = try hand.measuredPinch()
        let target = SIMD3(pinch.x + 0.04, pinch.y - 0.03, travelHeight(goTo))
        let mark = model.cueLog.count, wire = sentOnTheWire.count
        watchTheMove()
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
        XCTAssertEqual(cues(since: mark), [.holdLive, .drive(.arrived)], "\(mode): GO, the arrival, nothing more")
        assertOneHold("\(mode)", wireSince: wire)
    }

    func testATapOnTheGuideGoesThereSchemeA() throws {
        try aTapGoesThere(.screenTurns)
    }

    func testATapOnTheGuideGoesThereSchemeB() throws {
        try aTapGoesThere(.keyTurns)
    }

    /// The hand taps the view from above half way across its margin, on the operator's right of the work box: the
    /// point is in the drawn view but outside the box, so the tap is refused with NO and "Outside the work area.",
    /// heard once, and nothing starts, in the session or on the wire.
    private func aTapInTheMarginIsRefused(_ mode: ControlMode) throws {
        try start(mode, lock: .off, path: StallingPath())
        hand.reportGuidePanel()
        let goTo = try XCTUnwrap(model.assist.goTo)
        let panel = try XCTUnwrap(model.inputFacts().goPanel)
        let span = panel.boxHigh - panel.boxLow
        let margin = max(span.x, span.y) * GuideProjection.marginShare
        // Right is −X in the robot base.
        let outside = SIMD3(
            panel.boxLow.x - margin / 2, (panel.boxLow.y + panel.boxHigh.y) / 2, travelHeight(goTo))
        let point = panel.point(over: outside)
        XCTAssertTrue(panel.contains(x: point.x, y: point.y), "\(mode): the point is in the drawn view")
        XCTAssertFalse(
            panel.inBox(panel.target(x: point.x, y: point.y, travelHeight: goTo.travelHeightM)),
            "\(mode): and outside the box")
        let mark = model.cueLog.count, wire = sentOnTheWire.count
        watchTheMove()
        try hand.tapGuide(over: outside)
        hand.pump(2)
        let heard = Array(model.cueLog.dropFirst(mark))
        XCTAssertEqual(heard.map(\.event), [.refused(.outsideWorkArea)], "\(mode): heard once")
        XCTAssertEqual(heard.first?.haptic, .no, "\(mode)")
        XCTAssertEqual(heard.first?.speech, [.outside], "\(mode): Outside the work area.")
        XCTAssertEqual(heard.first?.dropped, false, "\(mode)")
        XCTAssertEqual(holdStarts, 0, "\(mode): the session started no hold")
        XCTAssertNil(model.controller.loose, "\(mode)")
        let sent = Array(sentOnTheWire.dropFirst(wire))
        XCTAssertFalse(sent.contains("pose_start"), "\(mode): no pose start on the wire: \(sent)")
        XCTAssertFalse(serverHolds, "\(mode): the server holds nothing")
    }

    func testATapInTheGuidesMarginIsRefusedSchemeA() throws {
        try aTapInTheMarginIsRefused(.screenTurns)
    }

    func testATapInTheGuidesMarginIsRefusedSchemeB() throws {
        try aTapInTheMarginIsRefused(.keyTurns)
    }

    /// A following move ends stopped short at a fresh reading more than this many arrive tolerances from the leg ahead.
    /// The number is the move's own, in the core, out of reach of the app's tests.
    private static let pathWatchTolerances = 2.5

    /// Against a server that keeps the arm within 4 cm of its start, half of the profile's box, the hand taps a point
    /// forward of the jaws, inside the box the guide draws, and the server holds the jaws short of it. The move ends
    /// and is heard once as stopped short. The operator steered nothing, so the server's clamp is told by that ending
    /// alone: GO, then the ending.
    ///
    /// Following, the server reports the pinch point and the move follows it. The jaws are held half way between the
    /// distance at which a fresh reading off the leg ahead ends the move and the farthest a correction reaches: the
    /// move would correct once it settled short, but that reading ends it first, so it never corrects. Not following,
    /// the server reports no pinch point and the move is planned as before. The jaws are held half way between
    /// arriving and the farthest a correction reaches: the move corrects at least once and at most as often as the
    /// profile allows.
    private func aMoveTheServerCutsShortEndsOnce(_ mode: ControlMode, following: Bool) throws {
        let serverBox = 0.04
        try start(mode, lock: .off, path: StallingPath(), serverBox: serverBox, reportsPinch: following)
        hand.reportGuidePanel()
        let goTo = try XCTUnwrap(model.assist.goTo)
        let pinch = try hand.measuredPinch()
        let watched = Self.pathWatchTolerances * goTo.arriveToleranceM, reach = goTo.correctionReachM
        let short = following ? (watched + reach) / 2 : (goTo.arriveToleranceM + reach) / 2
        // Forward is −Y in the robot base. In scheme B this tap lands in the centre band, the arrival's on a half.
        let target = SIMD3(pinch.x, pinch.y - serverBox - short, travelHeight(goTo))
        let mark = model.cueLog.count, wire = sentOnTheWire.count
        legs = CommandLegs(rest: goTo.settleS * 0.75, clock: { Date().timeIntervalSinceReferenceDate })
        watchTheMove()
        try hand.tapGuide(over: target)
        guard case .going = model.operating.state else {
            return XCTFail("\(mode): the screen shows \(model.operating.state)")
        }
        XCTAssertTrue(hand.wait(20, until: { !model.session.state.armMoving }), "\(mode): the move ended")
        XCTAssertEqual(endings(since: mark), [.drive(.ended(.stoppedShort))], "\(mode)")
        XCTAssertNil(model.controller.loose, "\(mode)")
        let corrections = legs?.corrections ?? 0
        if following {
            XCTAssertEqual(corrections, 0, "\(mode): the reading off the leg ahead ended it before any correction")
        } else {
            XCTAssertGreaterThan(corrections, 0, "\(mode): the jaws are held within a correction's reach")
            XCTAssertLessThanOrEqual(corrections, goTo.corrections, "\(mode): at most the profile's corrections")
        }
        XCTAssertTrue(hand.wait(2, until: { !serverHolds }), "\(mode): the server's hold ended")
        let (arm, armStart) = server.inspect { ($0.world.arm, $0.config.armStart) }
        XCTAssertEqual(arm.y, armStart.y - serverBox, accuracy: 0.003, "\(mode): the server held the arm at its box")
        let jaws = arm + server.config.toolOffset
        XCTAssertGreaterThan(simd_distance(jaws, target), goTo.arriveToleranceM, "\(mode): short of the target")
        hand.pump(0.5)
        XCTAssertEqual(cues(since: mark), [.holdLive, .drive(.ended(.stoppedShort))], "\(mode): nothing more")
        assertOneHold("\(mode)", wireSince: wire)
    }

    func testAFollowingMoveTheServerCutsShortStopsBeforeAnyCorrectionSchemeA() throws {
        try aMoveTheServerCutsShortEndsOnce(.screenTurns, following: true)
    }

    func testAFollowingMoveTheServerCutsShortStopsBeforeAnyCorrectionSchemeB() throws {
        try aMoveTheServerCutsShortEndsOnce(.keyTurns, following: true)
    }

    func testAMoveWithoutAPinchPointTheServerCutsShortCorrectsSchemeA() throws {
        try aMoveTheServerCutsShortEndsOnce(.screenTurns, following: false)
    }

    func testAMoveWithoutAPinchPointTheServerCutsShortCorrectsSchemeB() throws {
        try aMoveTheServerCutsShortEndsOnce(.keyTurns, following: false)
    }

    /// The network path stalls while the arm is on its way and comes back as soon as the move has ended: a move waits
    /// less long for arm data than the link waits before it gives up. The move ends on its own during the stall, it is
    /// heard once as no arm data, with no link hiccup and no lost link after it, and the link stays.
    private func aStallDuringAMoveEndsItOnce(_ mode: ControlMode) throws {
        let path = StallingPath()
        try start(mode, lock: .off, path: path)
        hand.reportGuidePanel()
        let goTo = try XCTUnwrap(model.assist.goTo)
        let pinch = try hand.measuredPinch()
        let target = SIMD3(pinch.x - 0.05, pinch.y - 0.03, travelHeight(goTo))
        let mark = model.cueLog.count, wire = sentOnTheWire.count
        watchTheMove()
        try hand.tapGuide(over: target)
        XCTAssertTrue(hand.wait(2, until: { serverHolds }), "\(mode): the server's hold runs")
        hand.pump(0.5)
        XCTAssertTrue(model.session.state.armMoving, "\(mode): on its way")
        path.stall()
        // Resumed at the move's end rather than after a fixed time, so a slow turn of the run loop cannot carry the
        // stall past the link's own wait. The limit only bounds a move that never ends.
        let endedDuringTheStall = hand.wait(10, until: { !model.session.state.armMoving })
        path.resume()
        XCTAssertTrue(endedDuringTheStall, "\(mode): the move ended on its own, with no arm data")
        XCTAssertTrue(hand.wait(2, until: { !serverHolds }), "\(mode): the server's hold ended")
        hand.pump(2)
        XCTAssertEqual(endings(since: mark), [.drive(.ended(.noArmData))], "\(mode)")
        XCTAssertEqual(
            cues(since: mark), [.holdLive, .drive(.ended(.noArmData))], "\(mode): no link hiccup or lost link after it")
        XCTAssertTrue(model.session.state.connected, "\(mode): the stall cost the move, not the link")
        XCTAssertNil(model.controller.loose, "\(mode)")
        assertOneHold("\(mode)", wireSince: wire)
    }

    func testAStallDuringAMoveIsHeardOnceAsNoArmDataSchemeA() throws {
        try aStallDuringAMoveEndsItOnce(.screenTurns)
    }

    func testAStallDuringAMoveIsHeardOnceAsNoArmDataSchemeB() throws {
        try aStallDuringAMoveEndsItOnce(.keyTurns)
    }

    /// The hand takes hold of the task object and lifts it 3 cm as the pick-and-place does, then taps the view from
    /// above over the goal: the jaws arrive at the tapped point at the travel height, "Arrived." is heard once, and the
    /// object the server reports went with them, still held well above where it rested.
    func testATapCarriesTheHeldObjectWithTheJaws() throws {
        try start(.screenTurns, lock: .off, path: StallingPath())
        let rested = try XCTUnwrap(model.link.objectPosition, "the local server reported no task object")
        let goal = try XCTUnwrap(model.link.goalPosition, "the local server reported no goal")
        guard hand.graspAndLift() else { return }
        hand.reportGuidePanel()
        let goTo = try XCTUnwrap(model.assist.goTo)
        let overGoal = SIMD3<Double>(model.profile.inBase(world: goal))
        let target = SIMD3(overGoal.x, overGoal.y, travelHeight(goTo))
        let mark = model.cueLog.count, wire = sentOnTheWire.count
        watchTheMove()
        try hand.tapGuide(over: target)
        guard case .going = model.operating.state else {
            return XCTFail("the screen shows \(model.operating.state)")
        }
        XCTAssertTrue(hand.wait(15, until: { !model.session.state.armMoving }), "the move ended")
        XCTAssertEqual(endings(since: mark), [.drive(.arrived)])
        XCTAssertTrue(hand.wait(2, until: { !serverHolds }), "the server's hold ended")
        let jaws = server.inspect { $0.world.arm + $0.config.toolOffset }
        XCTAssertLessThanOrEqual(
            simd_distance(jaws, target), goTo.arriveToleranceM, "the jaws at the tapped point, \(jaws)")
        hand.pump(2)
        let object = try XCTUnwrap(model.link.objectPosition, "the object's position")
        let held = SIMD3<Double>(model.profile.inBase(world: object))
        XCTAssertLessThan(
            simd_distance(SIMD2(held.x, held.y), SIMD2(jaws.x, jaws.y)), 0.01, "the object went with the jaws: \(held)")
        XCTAssertGreaterThan(object.z - rested.z, 0.015, "still held above where it rested")
        XCTAssertTrue(model.gripping, "the jaws still hold it")
        XCTAssertEqual(cues(since: mark), [.holdLive, .drive(.arrived)], "GO, the arrival, nothing more")
        assertOneHold("a carried go", wireSince: wire)
    }

    /// The hand taps for a move and touches the glass while the arm is on its way: the touch stops it at once, heard
    /// once as stopped by the operator. While that thumb stays down it rests past scheme B's dwell, the phone turns,
    /// and the thumb slides up the glass, any of which would turn the wrist or move the jaws from rest; nothing
    /// starts, in the session or on the wire.
    private func aTouchDuringAMoveStopsItAndStartsNothing(_ mode: ControlMode) throws {
        try start(mode, lock: .off, path: StallingPath())
        hand.reportGuidePanel()
        let goTo = try XCTUnwrap(model.assist.goTo)
        let pinch = try hand.measuredPinch()
        let target = SIMD3(pinch.x + 0.05, pinch.y + 0.03, travelHeight(goTo))
        let wire = sentOnTheWire.count
        watchTheMove()
        try hand.tapGuide(over: target)
        XCTAssertTrue(hand.wait(2, until: { serverHolds }), "\(mode): the server's hold runs")
        hand.pump(0.5)
        XCTAssertTrue(model.session.state.armMoving, "\(mode): on its way")
        let mark = model.cueLog.count, touchWire = sentOnTheWire.count
        // In scheme B a thumb resting on a half moves the jaws once its dwell is over.
        let thumb = mode == .keyTurns ? hand.half(.near) : hand.surfaceCentre
        let id = hand.touchDown(x: thumb.x, y: thumb.y)
        XCTAssertFalse(model.session.state.armMoving, "\(mode): the touch stops it at once")
        XCTAssertNil(model.controller.loose, "\(mode)")
        var started = Set<String>()
        let watchHolds = hand.watch
        hand.watch = { [unowned self] in
            watchHolds?()
            if model.session.state.wristMoving { started.insert("wrist") }
            if let jaws = model.session.state.gripperMoving { started.insert("jaws \(jaws)") }
        }
        hand.pump(1)
        hand.turnPhone(.turn, to: 30, in: 0.5)
        hand.pump(1)
        hand.slideUp(id, from: thumb, millimetres: 12, in: 0.25)
        hand.pump(1)
        hand.touchUp(id, x: thumb.x, y: thumb.y - 12 * hand.layout.pointsPerMm)
        hand.rotation = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1))
        hand.pump(1)
        XCTAssertEqual(started, [], "\(mode): the thumb started nothing while it stayed down")
        XCTAssertEqual(model.cueLog.dropFirst(mark).map(\.event), [.drive(.stoppedByYou)], "\(mode): heard once")
        XCTAssertTrue(hand.wait(2, until: { !serverHolds }), "\(mode): the server's hold ended")
        let afterTouch = Array(sentOnTheWire.dropFirst(touchWire))
        XCTAssertFalse(
            afterTouch.contains { $0 == "orient_start" || $0 == "gripper_jog_start" },
            "\(mode): no wrist or jaw start on the wire: \(afterTouch)")
        assertOneHold("\(mode)", wireSince: wire)
    }

    func testATouchDuringAMoveStopsItAndStartsNothingSchemeA() throws {
        try aTouchDuringAMoveStopsItAndStartsNothing(.screenTurns)
    }

    func testATouchDuringAMoveStopsItAndStartsNothingSchemeB() throws {
        try aTouchDuringAMoveStopsItAndStartsNothing(.keyTurns)
    }

    // MARK: A tap right after a hold

    /// The rules are told that the newest reading may be from before the server finished the last hold.
    private var tapWaits: Bool { model.inputFacts().arm?.heardAfterLastStop == false }

    /// The upper key holds the arm while the phone goes 6 cm to the operator's right in 0.2 s, quicker than the arm
    /// follows, and is let go of with the arm still on its way; `beforeTheStop` runs just before the stop goes out.
    private func holdAndLetGoOnTheWay(_ beforeTheStop: () -> Void) {
        hand.press(.upper)
        XCTAssertTrue(hand.wait(2, until: { serverHolds }), "the server's hold runs")
        hand.move(to: SIMD3(0.06, 0, 0), in: 0.2)
        beforeTheStop()
        hand.release(.upper)
        XCTAssertFalse(model.session.state.armMoving, "let go of")
    }

    /// A tap over `target` starts a move that goes there: "Arrived." is the one ending, and the jaws end within the
    /// profile's tolerance of the point.
    private func assertATapGoesThere(_ target: SIMD3<Double>, line: UInt = #line) throws {
        let goTo = try XCTUnwrap(model.assist.goTo, line: line)
        let mark = model.cueLog.count
        try hand.tapGuide(over: target)
        guard case .going = model.operating.state else {
            return XCTFail("the screen shows \(model.operating.state)", line: line)
        }
        XCTAssertTrue(hand.wait(15, until: { !model.session.state.armMoving }), "the move ended", line: line)
        XCTAssertEqual(endings(since: mark), [.drive(.arrived)], line: line)
        XCTAssertTrue(hand.wait(2, until: { !serverHolds }), "the server's hold ended", line: line)
        let jaws = server.inspect { $0.world.arm + $0.config.toolOffset }
        XCTAssertLessThanOrEqual(
            simd_distance(jaws, target), goTo.arriveToleranceM, "the jaws at the tapped point, \(jaws)", line: line)
    }

    /// The hand lets go of a hold with the arm on its way, the network path stalls right after the stop, and the hand
    /// taps the guide at once: the newest reading is from before the stop, and the server would start the move from
    /// wherever the arm stood when it finished, so the tap is refused with "Wait." and nothing goes on the wire. Once
    /// the server has finished the hold, its answer held back on the way, the path comes back with that answer, which
    /// ends the wait before the link's own wait for it would have; the same tap then goes and arrives at the tapped
    /// point.
    func testATapBeforeTheStopsAnswerWaitsAndGoesOnceItCame() throws {
        let path = StallingPath()
        try start(.screenTurns, lock: .off, path: path)
        XCTAssertTrue(hand.wait(4, until: { model.link.observerUp }), "the listening connection is up")
        hand.reportGuidePanel()
        let pinch = try hand.measuredPinch()
        let goTo = try XCTUnwrap(model.assist.goTo)
        // Right is −X and forward −Y in the robot base: 3 cm right of and 3 cm forward of where the jaws began.
        let target = SIMD3(pinch.x - 0.03, pinch.y - 0.03, travelHeight(goTo))
        holdAndLetGoOnTheWay { path.stall(after: "pose_stop") }
        let stopped = Date()
        let mark = model.cueLog.count, wire = sentOnTheWire.count
        try hand.tapGuide(over: target)
        XCTAssertEqual(cues(since: mark), [.refused(.notReady)], "refused once")
        XCTAssertEqual(model.cueLog.dropFirst(mark).first?.speech, [.wait], "as Wait.")
        XCTAssertNil(model.controller.loose)
        XCTAssertTrue(hand.wait(2, until: { !serverHolds }), "the server finished the hold")
        XCTAssertFalse(sentOnTheWire.dropFirst(wire).contains("pose_start"), "nothing went on the wire")
        XCTAssertTrue(tapWaits, "the answer is held back")
        path.resume()
        XCTAssertTrue(hand.wait(2, until: { !tapWaits }), "the stop's answer ends the wait")
        XCTAssertLessThan(
            Date().timeIntervalSince(stopped), Double(TeleopLink.finishWaitMs) / 1000,
            "the answer ended it, before the link's own wait for it would have")
        try assertATapGoesThere(target)
    }

    /// The same, with the stop's answer lost on the control connection while the listening connection goes on
    /// reporting: the tap waits no longer than the link waits for a final answer, and then goes and arrives.
    func testATapWaitsNoLongerThanTheLinkWaitsForALostAnswer() throws {
        let path = StopAnswerLosingPath()
        try start(.screenTurns, lock: .off, transport: path.transport)
        XCTAssertTrue(hand.wait(4, until: { model.link.observerUp }), "the listening connection is up")
        hand.reportGuidePanel()
        let pinch = try hand.measuredPinch()
        let goTo = try XCTUnwrap(model.assist.goTo)
        let target = SIMD3(pinch.x - 0.03, pinch.y - 0.03, travelHeight(goTo))
        holdAndLetGoOnTheWay { path.loseTheNextStopsAnswer() }
        let stopped = Date()
        let mark = model.cueLog.count, wire = path.sent.count
        try hand.tapGuide(over: target)
        XCTAssertEqual(cues(since: mark), [.refused(.notReady)], "refused once")
        XCTAssertEqual(model.cueLog.dropFirst(mark).first?.speech, [.wait], "as Wait.")
        XCTAssertFalse(path.sent.dropFirst(wire).contains("pose_start"), "nothing went on the wire")
        XCTAssertTrue(hand.wait(3, until: { !tapWaits }), "the wait ends")
        let waited = Date().timeIntervalSince(stopped)
        XCTAssertGreaterThan(waited, Double(TeleopLink.finishWaitMs) / 1000 - 0.05, "not before the link's own wait")
        XCTAssertTrue(path.lost.contains("ack"), "the server answered, and the answer was lost: \(path.lost)")
        try assertATapGoesThere(target)
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

/// The legs a going move's command walked, read from the offsets the link is asked to send, sampled on every turn of
/// the run loop. Once a leg's command reaches the leg's end it stays there exactly, so an offset that has not changed
/// for `rest` is a command standing still. A correction begins only after the arm has settled short, which takes the
/// profile's settle time, so it always sets off from such a stand. A stand is measured from the first sample that
/// showed the offset to the last one that still showed it: the command moves on its own clock, so a turn of the run
/// loop that comes late (a stall of the test host's main thread) says nothing about whether it stood still meanwhile.
private final class CommandLegs {
    private let rest: TimeInterval
    private let clock: () -> TimeInterval
    private var last: SIMD3<Double>?
    /// When the offset `last` was first sampled, and when it was sampled last.
    private var changedAt: TimeInterval = 0
    private var lastSampledAt: TimeInterval = 0
    /// Each time the command set off after standing still: where it stood, measured from where the move began, and
    /// which way it went, robot base frame.
    private(set) var setOffs: [(from: SIMD3<Double>, way: SIMD3<Double>)] = []

    /// - Parameters:
    ///   - rest: how long an unchanged offset must last to count as standing still; under the settle time.
    ///   - clock: the time now, seconds.
    init(rest: TimeInterval, clock: @escaping () -> TimeInterval) {
        self.rest = rest
        self.clock = clock
    }

    func sample(_ offset: SIMD3<Double>?) {
        let now = clock()
        defer {
            last = offset
            lastSampledAt = now
        }
        guard let offset, let last else {
            changedAt = now
            return
        }
        guard offset != last else { return }
        if lastSampledAt - changedAt >= rest {
            setOffs.append((OperatorFrame.base(fromLink: last), OperatorFrame.base(fromLink: offset - last)))
        }
        changedAt = now
    }

    /// The set-offs that were corrections: every one but the level leg leaving the corner above the start, where the
    /// command may wait for the arm to reach the travel height.
    var corrections: Int {
        setOffs.filter { stand in
            let atTheCorner = abs(stand.from.x) < 0.0005 && abs(stand.from.y) < 0.0005
            let level = abs(stand.way.z) < simd_length(SIMD2(stand.way.x, stand.way.y))
            return !(atTheCorner && level)
        }.count
    }
}

/// The helper that counts a going move's corrections from outside, on a clock it is handed: it counts a stand of the
/// command only between samples that show it, so a gap in sampling, such as a stall of the test host's main thread
/// while the command moves, is never taken for one.
final class CommandLegsTests: XCTestCase {
    /// The settle time of the simulator's profile, three quarters of it, as the local runs use. A profile without
    /// tap-to-go has none, and every count below then fails.
    private let rest = (RobotProfile.so101Simulator.assist.goTo?.settleS ?? .nan) * 0.75
    private let speed = 0.04
    private var now: TimeInterval = 0

    /// The command, robot base frame, `t` seconds into a move: a 6 cm level leg forward from where the move began, a
    /// stand of `stand` seconds at its end, a 2 cm correction further forward, and a stand at the end of that.
    private func command(at t: TimeInterval, stand: TimeInterval) -> SIMD3<Double> {
        let leg = 0.06 / speed
        let forward: Double
        if t < leg {
            forward = speed * t
        } else if t < leg + stand {
            forward = 0.06
        } else {
            forward = 0.06 + min(0.02, speed * (t - leg - stand))
        }
        return SIMD3(0, -forward, 0)
    }

    /// Samples the command every 4 ms for 3.5 s plus `stand`, but none in `gap`, and returns the corrections counted.
    private func corrections(stand: TimeInterval, gap: ClosedRange<TimeInterval>? = nil) -> Int {
        now = 0
        let legs = CommandLegs(rest: rest, clock: { [unowned self] in now })
        var t = 0.0
        while t <= 3.5 + stand {
            now = t
            if gap?.contains(t) != true { legs.sample(OperatorFrame.link(fromBase: command(at: t, stand: stand))) }
            t += 0.004
        }
        return legs.corrections
    }

    /// The leg's stand and the correction from it: one correction, sampled throughout or not while the command stands.
    func testARealStandIsAStand() {
        XCTAssertEqual(corrections(stand: 0.7), 1, "sampled throughout")
        XCTAssertEqual(corrections(stand: 0.7, gap: 1.7...2.0), 1, "with 0.3 s of the stand not sampled")
    }

    /// A gap in sampling of 0.46 s, longer than `rest`, while the command moves along the leg is not a stand.
    func testAGapInSamplingWhileTheCommandMovesIsNotAStand() {
        XCTAssertEqual(corrections(stand: 0.7, gap: 0.1...0.56), 1)
        XCTAssertEqual(corrections(stand: 0.7, gap: 2.25...2.71), 1, "nor one in the correction")
    }

    /// The stand counts from the first sample that shows the offset to the last one that still shows it: exactly
    /// `rest` between them is a stand, a sample interval less is not.
    func testAStandIsMeasuredBetweenTheSamplesThatShowIt() {
        for (lasted, counted) in [(rest, 1), (rest - 0.004, 0)] {
            now = 0
            let legs = CommandLegs(rest: rest, clock: { [unowned self] in now })
            let start = OperatorFrame.link(fromBase: SIMD3(0.01, -0.02, 0))
            let moved = OperatorFrame.link(fromBase: SIMD3(0.01, -0.03, 0))
            legs.sample(OperatorFrame.link(fromBase: SIMD3(0.01, -0.01, 0)))
            now = 0.1
            legs.sample(start)
            now = 0.1 + lasted
            legs.sample(start)
            now = 0.1 + lasted + 0.3
            legs.sample(moved)
            XCTAssertEqual(legs.corrections, counted, "\(lasted) s")
        }
    }
}

/// Under both of the app's sockets, a real WebSocket to the local server that can lose the answer to a stop: from the
/// app's `pose_stop` until its next `pose_start`, everything the server sends on the control connection, the first one
/// opened, is lost, except the echoes of the link's probes. The listening connection goes on reporting.
private final class StopAnswerLosingPath {
    /// The type of every message the app sent on its control connection, in order.
    private(set) var sent: [String] = []
    /// The type of every message the server sent on the control connection that was lost.
    private(set) var lost: [String] = []
    private var opened = 0
    private var armed = false
    private var losing = false

    /// The answer to the app's next `pose_stop` is lost.
    func loseTheNextStopsAnswer() { armed = true }

    func transport(_ url: URL) -> LinkTransport {
        opened += 1
        return AnswerLosingTransport(url: url, path: self, control: opened == 1)
    }

    fileprivate func app(sent type: String) {
        sent.append(type)
        if type == "pose_stop", armed {
            armed = false
            losing = true
        } else if type == "pose_start" {
            losing = false
        }
    }

    /// Whether the server's message of `type` on the control connection reaches the app.
    fileprivate func passes(_ type: String) -> Bool {
        guard losing, type != "test" else { return true }
        lost.append(type)
        return false
    }

    fileprivate static func type(of text: String) -> String {
        let message = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        return message?["type"] as? String ?? "?"
    }
}

/// One of the app's sockets through a `StopAnswerLosingPath`.
private final class AnswerLosingTransport: LinkTransport {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    private let socket: WebSocketTransport
    private let path: StopAnswerLosingPath
    private let control: Bool

    init(url: URL, path: StopAnswerLosingPath, control: Bool) {
        socket = WebSocketTransport(url: url)
        self.path = path
        self.control = control
        socket.onText = { [weak self] text in
            guard let self else { return }
            if self.control, !self.path.passes(StopAnswerLosingPath.type(of: text)) { return }
            self.onText?(text)
        }
        socket.onClose = { [weak self] in self?.onClose?() }
    }

    func open() { socket.open() }
    func send(_ text: String) {
        if control { path.app(sent: StopAnswerLosingPath.type(of: text)) }
        socket.send(text)
    }
    func close() { socket.close() }
}
