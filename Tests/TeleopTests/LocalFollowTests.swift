import simd
import TeleopCore
import TeleopServerHost
import TeleopServerModel
import XCTest
@testable import Teleop

/// A move to a tapped point against the server model on a local socket in real time, with a gripper whose pinch point
/// turns with the arm's posture, as the simulator's does: the server reports that pinch point, and the move follows
/// it. From the reset pose a tap arrives within the profile's tolerance, heard as GO and "Arrived." alone. On an arm
/// folded so that its jaws go the other way from the gripper link, a tap where they cannot reach stops short by
/// itself, heard as GO and the stopped-short ending alone. A server that stops reporting the pinch point during a
/// move ends it stopped short, the arm stops, and what the link is asked to send never jumps on the way.
final class LocalFollowTests: XCTestCase {
    private var server: LocalTeleopServer!
    private var hand: ScriptedOperator!
    private var savedTaskAid: Any?
    private var model: AppModel { hand.model }
    private var turn: ServerModelConfig.ToolTurn!

    /// The task aid is put back as it was. Both of the aids' settings are removed, never put back: a launch argument
    /// shadows the saved value, so a value read here and written back could be the argument's, saved for good.
    override func tearDown() {
        hand?.watch = nil
        hand?.finish()
        hand = nil
        server?.stop()
        server = nil
        UserDefaults.standard.set(savedTaskAid, forKey: AppModel.taskAidKey)
        UserDefaults.standard.removeObject(forKey: AppModel.assistKey)
        UserDefaults.standard.removeObject(forKey: AppModel.lockChoiceKey)
        super.tearDown()
    }

    /// A server whose pinch point turns as `turn` says, the aids on with no lock, both connections up, and the guide's
    /// view from above reported.
    private func start(_ turn: ServerModelConfig.ToolTurn) throws {
        self.turn = turn
        var config = ServerModelConfig.s4Simulator(stepsPerSecond: 60, reportsToolPoint: true)
        config.toolTurn = turn
        server = LocalTeleopServer(config: config)
        try server.start()
        hand = ScriptedOperator(address: server.address, mode: .screenTurns, smoothing: 0.3, pace: 0.3)
        savedTaskAid = UserDefaults.standard.object(forKey: AppModel.taskAidKey)
        hand.model.taskAid = true
        // Through the setters, which set the model's own value whatever a launch argument says.
        hand.model.assistOn = true
        hand.model.lockChoice = .off
        XCTAssertTrue(hand.connect(within: TestWaits.linkUp), "could not connect to the local server")
        XCTAssertTrue(hand.wait(TestWaits.linkUp, until: { model.link.observerUp }), "the listening connection is up")
        hand.pump(1)
        hand.reportGuidePanel()
    }

    private var arm: SIMD3<Double> { server.inspect { $0.world.arm } }
    /// Where the jaws pinch on the server, robot base frame.
    private var jaws: SIMD3<Double> { turn.pinch(arm) }
    private var serverHolds: Bool { server.inspect { $0.state["ik"]?.stringValue } == "pose_tracking" }
    private func cues(since mark: Int) -> [CueKey] { model.cueLog.dropFirst(mark).map(\.event) }
    private func endings(since mark: Int) -> [CueKey] {
        model.cueLog.dropFirst(mark).map(\.event).filter(LooseEndingHeardTests.isEndingCue)
    }

    private func travelHeight(_ goTo: GoToLimits) -> Double { Double(model.profile.tableHeight) + goTo.travelHeightM }

    /// A point the jaws can reach at the travel height: where they pinch with the gripper link moved `by` (robot base
    /// frame, across the table) from where the server put it at the reset, at the height that brings them to the
    /// travel height.
    private func reachable(by move: SIMD2<Double>, _ goTo: GoToLimits) -> SIMD3<Double> {
        let start = server.config.armStart
        let place = SIMD2(start.x, start.y) + move
        let height = turn.armHeight(over: place, pinchAt: travelHeight(goTo))
        let pinch = turn.pinch(SIMD3(place.x, place.y, height))
        return SIMD3(pinch.x, pinch.y, travelHeight(goTo))
    }

    /// The hand taps the view from above over a point the jaws can reach, 4.5 cm to the left of the gripper link's
    /// reset place and 1.5 cm forward of it, which the pinch point does not reach by moving as the gripper link does:
    /// the move ends within the profile's tolerance of the tapped point, the server's hold ends with it, and GO and
    /// "Arrived." are all that is heard.
    func testATapFromTheResetPoseArrivesWhereTheJawsTurn() throws {
        try start(.s4Simulator)
        let goTo = try XCTUnwrap(model.assist.goTo)
        let target = reachable(by: SIMD2(0.045, -0.015), goTo)
        XCTAssertGreaterThan(
            simd_distance(reachable(by: .zero, goTo) + SIMD3(0.045, -0.015, 0), target), 0.02,
            "moved as the gripper link is, the pinch point would end more than 2 cm from the target")
        let mark = model.cueLog.count
        try hand.tapGuide(over: target)
        guard case .going = model.operating.state else {
            return XCTFail("the screen shows \(model.operating.state)")
        }
        XCTAssertTrue(hand.wait(30, until: { !model.session.state.armMoving }), "the move ended")
        XCTAssertEqual(endings(since: mark), [.drive(.arrived)])
        XCTAssertTrue(hand.wait(2, until: { !serverHolds }), "the server's hold ended")
        XCTAssertLessThanOrEqual(
            simd_distance(jaws, target), goTo.arriveToleranceM, "the jaws at the tapped point, \(jaws)")
        hand.pump(0.5)
        XCTAssertEqual(cues(since: mark), [.holdLive, .drive(.arrived)], "GO, the arrival, nothing more")
    }

    /// An arm folded so far that its pinch point goes inward when the gripper link goes outward. The hand taps 4 cm
    /// farther from the pan axis than the jaws, where no place of the gripper link in the server's box brings them: the
    /// move stops short by itself, the server's hold ends, and GO and the stopped-short ending are all that is heard,
    /// with no blocked cue, no clamp and no lowest height.
    func testATapTheJawsCannotReachStopsShortAndIsHeardOnce() throws {
        var folded = ServerModelConfig.ToolTurn.s4Simulator
        folded.tiltPerRadius = -25
        try start(folded)
        let goTo = try XCTUnwrap(model.assist.goTo)
        let from = jaws
        let out = SIMD2(from.x, from.y) - folded.panAxis
        let farther = SIMD2(from.x, from.y) + out / simd_length(out) * 0.04
        let target = SIMD3(farther.x, farther.y, travelHeight(goTo))
        // Every place of the gripper link in the server's box, 2 mm apart, at the height that brings the jaws to the
        // travel height: none brings them within twice the tolerance of how far out the target is.
        let low = server.config.armStart - SIMD3(repeating: server.config.workspaceHalfSize)
        let high = server.config.armStart + SIMD3(repeating: server.config.workspaceHalfSize)
        var farthest = 0.0
        for x in stride(from: low.x, through: high.x, by: 0.002) {
            for y in stride(from: low.y, through: high.y, by: 0.002) {
                let height = folded.armHeight(over: SIMD2(x, y), pinchAt: travelHeight(goTo))
                guard height >= low.z, height <= high.z else { continue }
                let pinch = folded.pinch(SIMD3(x, y, height))
                farthest = max(farthest, simd_length(SIMD2(pinch.x, pinch.y) - folded.panAxis))
            }
        }
        XCTAssertLessThan(farthest, simd_length(farther - folded.panAxis) - 2 * goTo.arriveToleranceM, "out of reach")
        let mark = model.cueLog.count
        try hand.tapGuide(over: target)
        guard case .going = model.operating.state else {
            return XCTFail("the screen shows \(model.operating.state)")
        }
        XCTAssertTrue(hand.wait(30, until: { !model.session.state.armMoving }), "the move ended")
        XCTAssertEqual(endings(since: mark), [.drive(.ended(.stoppedShort))])
        XCTAssertNil(model.controller.loose)
        XCTAssertTrue(hand.wait(2, until: { !serverHolds }), "the server's hold ended")
        XCTAssertGreaterThan(simd_distance(jaws, target), goTo.arriveToleranceM, "short of the target")
        hand.pump(0.5)
        XCTAssertEqual(cues(since: mark), [.holdLive, .drive(.ended(.stoppedShort))], "GO, the ending, nothing more")
    }

    /// The hand taps for a move, and once the arm is on its way the server stops reporting the pinch point: the move
    /// ends stopped short at the next reading, heard as GO and that ending alone, and the arm stops. On every turn of
    /// the run loop until then, what the link is asked to send moves no farther than the profile's speed allows in
    /// the time since the last turn, plus half the largest change of the reported offset (pinch point less gripper
    /// link) between any two readings, the reading at the tap included, for each reading that can have come in that
    /// time: half that change is the most one reading can move it.
    func testAServerThatStopsReportingThePinchPointEndsTheMoveAndNothingJumps() throws {
        try start(.s4Simulator)
        let goTo = try XCTUnwrap(model.assist.goTo)
        let target = reachable(by: SIMD2(0.045, -0.015), goTo)
        var offsets: [SIMD3<Double>] = []
        func noteReading() {
            guard let state = model.link.newestArmState, let tool = state.toolPoint, let link = state.endEffector
            else { return }
            if offsets.last != tool - link { offsets.append(tool - link) }
        }
        noteReading()
        var largestChange = 0.0
        var previous: (at: TimeInterval, offset: SIMD3<Double>)?
        var worst: (excess: Double, at: TimeInterval) = (-.infinity, 0)
        hand.watch = { [unowned self] in
            let before = offsets.count
            noteReading()
            for new in offsets.dropFirst(max(before, 1)) {
                for old in offsets where old != new { largestChange = max(largestChange, simd_distance(new, old)) }
            }
            let now = Date().timeIntervalSinceReferenceDate
            guard let offset = model.controller.goOffset() else {
                previous = nil
                return
            }
            if let previous {
                // Readings come about every 0.2 s; a late turn of the run loop may span more than one.
                let readings = 1 + ((now - previous.at) / 0.15).rounded(.down)
                let allowed = goTo.speedMps * (now - previous.at) + readings * largestChange / 2
                let excess = simd_distance(offset, previous.offset) - allowed
                if excess > worst.excess { worst = (excess, now) }
            }
            previous = (now, offset)
        }
        let mark = model.cueLog.count
        let from = arm
        try hand.tapGuide(over: target)
        guard case .going = model.operating.state else {
            return XCTFail("the screen shows \(model.operating.state)")
        }
        XCTAssertTrue(hand.wait(15, until: { simd_distance(arm, from) > 0.01 }), "the arm is on its way")
        XCTAssertTrue(model.session.state.armMoving, "still going")
        server.inspect { $0.reportsToolPoint = false }
        XCTAssertTrue(hand.wait(3, until: { !model.session.state.armMoving }), "the move ended")
        XCTAssertEqual(endings(since: mark), [.drive(.ended(.stoppedShort))])
        XCTAssertNil(model.controller.loose)
        XCTAssertTrue(hand.wait(2, until: { !serverHolds }), "the server's hold ended")
        let stopped = arm
        hand.pump(1)
        XCTAssertLessThan(simd_distance(arm, stopped), 0.001, "the arm stays where it stopped")
        XCTAssertEqual(cues(since: mark), [.holdLive, .drive(.ended(.stoppedShort))], "GO, the ending, nothing more")
        XCTAssertGreaterThan(offsets.count, 2, "readings of a turning pinch point came during the move")
        XCTAssertLessThanOrEqual(worst.excess, 1e-6, "a jump in what the link is asked to send")
    }
}
