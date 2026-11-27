import simd
import TeleopCore
import TeleopServerHost
import TeleopServerModel
import XCTest
@testable import Teleop

/// A socket that keeps what the app sends and lets the test speak for the server.
private final class AidsTestTransport: LinkTransport {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    var sent: [[String: Any]] = []

    func open() {}
    func close() {}
    func send(_ text: String) {
        sent.append(try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])
    }

    var types: [String] { sent.map { $0["type"] as! String } }

    func server(_ type: String, seq: Int = 0, _ payload: [String: Any] = [:]) {
        let message: [String: Any] = ["v": 1, "type": type, "ts": 0, "seq": seq, "payload": payload]
        onText?(String(data: try! JSONSerialization.data(withJSONObject: message), encoding: .utf8)!)
    }
}

/// The guide's aids that the link runs, against a scripted server: the work-area rule tells every time the commanded
/// point leaves the work box, on which side, and the server's clamp END for that hold is then left out; a floor the
/// table stops the arm before is not told, and a push into the table is told by the lowest rule alone, while that rule
/// runs (without it the floor is watched like any other face); the side is read only while a translation is commanded;
/// a start the link re-sends inside one press is not a new press; the switch reaches the link. Against the server
/// model, an arm that cannot go lower says so. With the aids off the cues are version 1.0.1's.
final class GuideAidsLinkTests: XCTestCase {
    private var transport: AidsTestTransport!
    private var position: SIMD3<Float>? = .zero
    private var clock = 10_000
    private var model: AppModel!
    private var felt = SpyHaptics()
    private var speech = SpySpeech()
    private var savedLanguage = L10n.language

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.language
        L10n.language = .en
    }

    /// Both of the aids' settings are removed, never put back: a launch argument shadows the saved value, so a value
    /// read here and written back could be the argument's, saved for good.
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppModel.assistKey)
        UserDefaults.standard.removeObject(forKey: AppModel.lockChoiceKey)
        L10n.language = savedLanguage
        super.tearDown()
    }

    /// Standby on the real server with the link up and the gripper link reported at `arm` (robot base frame), the aids
    /// given to the model without saving them, and nothing felt or heard yet.
    private func bringUp(
        aids: Bool, arm: SIMD3<Double>, tool: SIMD3<Double>? = nil, profile: RobotProfile = TestProfiles.so101
    ) {
        position = .zero
        clock = 10_000
        felt = SpyHaptics()
        speech = SpySpeech()
        model = AppModel(
            start: .p4, haptics: felt, sounds: SpySounds(), speech: speech,
            pose: { [unowned self] in position.map { TestPose.portrait(at: $0) } },
            liveLink: true,
            makeTransport: { [unowned self] _ in
                let made = AidsTestTransport()
                transport = made
                return made
            },
            makeObserverTransport: { _ in AidsTestTransport() },
            nowMs: { [unowned self] in clock }, clientName: "teleop-ios/1.0.0 (7)", profile: profile,
            assistOn: aids, lockChoice: .off
        )
        model.session.state.serverAddress = "100.64.0.1:8765"
        // Exact offsets: the hand's movement is the command.
        model.session.state.setSmoothing(0)
        model.connect()
        transport.server("welcome")
        transport.server("state", state(arm, tool: tool))
        felt.felt = []
        speech.spoken = []
    }

    /// A `state` with the gripper link at `arm`, and the server's own label and tool point when given.
    private func state(_ arm: SIMD3<Double>, ik: String? = nil, tool: SIMD3<Double>? = nil) -> [String: Any] {
        var state: [String: Any] = ["estop": false, "gripper": "closed", "ee_pos": [arm.x, arm.y, arm.z]]
        if let ik { state["ik"] = ik }
        if let tool { state["tool_pos"] = [tool.x, tool.y, tool.z] }
        return state
    }

    /// The work box in gripper-link space: the profile's box, kept for the pinch point, less its tool offset.
    private func gripperBox(_ profile: RobotProfile = TestProfiles.so101) -> (low: SIMD3<Double>, high: SIMD3<Double>) {
        let low = profile.workspaceMin - profile.toolOffset
        let high = profile.workspaceMax - profile.toolOffset
        return (SIMD3<Double>(low), SIMD3<Double>(high))
    }

    /// Where the gripper link is after a reset: the box is centred on it.
    private var resetPose: SIMD3<Double> {
        let box = gripperBox()
        return (box.low + box.high) / 2
    }

    /// One pose tick, 33 ms later.
    private func tick() {
        clock += 33
        model.link.tick()
    }

    /// Many ticks with a server that answers every probe, as a live one does.
    private func run(ticks: Int) {
        var answered = transport.sent.count
        for _ in 0..<ticks {
            tick()
            for message in transport.sent.dropFirst(answered) where message["type"] as? String == "test" {
                transport.server("test", seq: message["seq"] as! Int)
            }
            answered = transport.sent.count
        }
    }

    private func lastSeq(of type: String) -> Int {
        transport.sent.last { $0["type"] as? String == type }!["seq"] as! Int
    }

    /// The server's final ack for the newest translation hold and a state with the arm at `arm`.
    private func serverFinishesHold(armAt arm: SIMD3<Double>) {
        let start = lastSeq(of: "pose_start")
        transport.server("ack", seq: start, ["seq": start, "status": "ok", "reason": "pose_stopped"])
        transport.server("state", state(arm))
    }

    /// The hand goes `centimetres` forward (ARKit forward is −z), one centimetre a tick.
    private func handForward(_ centimetres: Int) {
        for step in 1...centimetres {
            position = SIMD3(0, 0, -0.01 * Float(step))
            tick()
        }
    }

    private var cues: [CueKey] { model.cueLog.map(\.event) }

    private var sidesTold: [OperatorDirection] {
        cues.compactMap {
            guard case .commandOutside(let side) = $0 else { return nil }
            return side
        }
    }

    /// The hand goes 10 cm forward from the reset pose. A server hold asks for at most 8 cm, which takes the commanded
    /// point to the forward face and no farther; 1.5 s on the link ends that hold to learn where the arm got to, the
    /// server reports it at the face, and the next hold asks for the last 2 cm, past it. The server then reports its
    /// own label and its clamp.
    private func handTenCentimetresForwardFromTheResetPose() {
        let face = resetPose - SIMD3(0, 0.08, 0)
        model.send(.holdArmStart)
        handForward(10)
        XCTAssertTrue(model.catchingUp)
        XCTAssertNil(model.link.commandOutside, "8 cm takes the command to the face, not past it")
        run(ticks: 40)
        XCTAssertEqual(transport.types.last { $0 != "test" }, "pose_stop", "the link asks where the arm got to")
        serverFinishesHold(armAt: face)
        XCTAssertEqual(transport.types.last, "pose_start")
        tick()
        transport.server("state", state(face, ik: "pose_tracking"))
        transport.server("state", state(face, ik: "pose_clamped"))
        run(ticks: 5)
        XCTAssertTrue(model.session.state.armMoving)
    }

    func testTenCentimetresForwardIsToldOnceAndTheServersClampIsNotFeltAgain() {
        bringUp(aids: true, arm: resetPose)
        handTenCentimetresForwardFromTheResetPose()
        XCTAssertEqual(model.link.commandOutside, .forward)
        XCTAssertEqual(sidesTold, [.forward])
        XCTAssertFalse(cues.contains(.limit(.workspace)), "one crossing, one buzz")
        XCTAssertEqual(felt.felt, [.play(.go), .play(.end)])
        XCTAssertEqual(speech.spoken, ["Too far forward."])
    }

    func testWithTheAidsOffTheServersClampIsFeltAsInOneZeroOne() {
        bringUp(aids: false, arm: resetPose)
        handTenCentimetresForwardFromTheResetPose()
        XCTAssertNil(model.link.commandOutside)
        XCTAssertEqual(sidesTold, [])
        XCTAssertEqual(cues.filter { $0 == .limit(.workspace) }.count, 1)
        XCTAssertEqual(felt.felt, [.play(.go), .play(.end)])
        XCTAssertEqual(speech.spoken, [])
    }

    /// A clamp the rule did not see coming, here with the commanded point well inside the profile's box (a server whose
    /// box differs from the profile's), is still felt.
    func testAClampTheRuleDidNotForeseeIsStillFelt() {
        bringUp(aids: true, arm: resetPose)
        model.send(.holdArmStart)
        run(ticks: 12)
        transport.server("state", state(resetPose, ik: "pose_tracking"))
        transport.server("state", state(resetPose, ik: "pose_clamped"))
        XCTAssertEqual(sidesTold, [])
        XCTAssertEqual(cues.filter { $0 == .limit(.workspace) }.count, 1)
        XCTAssertEqual(felt.felt, [.play(.go), .play(.end)])
    }

    /// Pushed slowly, the server clamps at the face before the commanded point is past the rule's slack. That clamp is
    /// the crossing: the rule tells its side at once, the line shows it, the server's END is left out, and nothing more
    /// is told as the point goes on out.
    func testASlowCrossingTheServerClampsFirstIsToldOnceWithItsSide() {
        // 9.65 mm inside the forward face (base −y), so no step lands on the face or on the slack's boundary.
        let start = SIMD3(resetPose.x, gripperBox().low.y + 0.00965, resetPose.z)
        bringUp(aids: true, arm: start)
        model.send(.holdArmStart)
        // Forward a millimetre a tick (ARKit forward is −z): after 11, 1.35 mm past the face, inside the slack.
        for step in 1...11 {
            position = SIMD3(0, 0, -0.001 * Float(step))
            tick()
        }
        XCTAssertNil(model.link.commandOutside, "inside the slack")
        XCTAssertEqual(sidesTold, [])
        transport.server("state", state(start, ik: "pose_tracking"))
        transport.server("state", state(start, ik: "pose_clamped"))
        XCTAssertEqual(model.link.commandOutside, .forward, "the line says what the cue says")
        XCTAssertEqual(sidesTold, [.forward])
        for step in 12...30 {
            position = SIMD3(0, 0, -0.001 * Float(step))
            tick()
            transport.server("state", state(start, ik: "pose_clamped"))
        }
        XCTAssertEqual(model.link.commandOutside, .forward)
        XCTAssertEqual(sidesTold, [.forward])
        XCTAssertFalse(cues.contains(.limit(.workspace)), "one crossing, one buzz")
        XCTAssertEqual(felt.felt, [.play(.go), .play(.end)])
        XCTAssertEqual(speech.spoken, ["Too far forward."])
    }

    /// The server's END is left out only in the hold in which the rule spoke: in the next hold, a clamp the rule did
    /// not foresee (the commanded point well inside the box) is felt.
    func testTheServersClampIsLeftOutOnlyInTheHoldTheRuleSpokeIn() {
        let start = SIMD3(resetPose.x, gripperBox().low.y + 0.01, resetPose.z)
        bringUp(aids: true, arm: start)
        model.send(.holdArmStart)
        handForward(3)
        transport.server("state", state(start, ik: "pose_tracking"))
        transport.server("state", state(start, ik: "pose_clamped"))
        XCTAssertEqual(sidesTold, [.forward])
        XCTAssertFalse(cues.contains(.limit(.workspace)), "the rule told this hold's crossing")
        model.send(.holdArmEnd)
        serverFinishesHold(armAt: start)
        run(ticks: 50)
        position = .zero
        model.send(.holdArmStart)
        run(ticks: 12)
        XCTAssertNil(model.link.commandOutside, "inside the box")
        transport.server("state", state(start, ik: "pose_tracking"))
        transport.server("state", state(start, ik: "pose_clamped"))
        XCTAssertEqual(sidesTold, [.forward])
        XCTAssertEqual(cues.filter { $0 == .limit(.workspace) }.count, 1, "felt in the next hold")
        XCTAssertEqual(felt.felt.filter { $0 == .play(.end) }.count, 2, "the side told, then the clamp")
        XCTAssertEqual(felt.felt.last, .play(.end))
    }

    /// The simulator's box floor is below its table: the table stops the arm first, and the lowest rule tells that, so
    /// the work-area rule does not also say "Too low.". On a profile whose box floor is above the table it does.
    func testAFloorBelowTheTableIsNotToldAndOneAboveItIs() {
        let simulator = TestProfiles.so101
        XCTAssertLessThan(simulator.workspaceMin.z, simulator.tableHeight, "the simulator's floor is below its table")
        var tableBelowTheBox = simulator
        tableBelowTheBox.tableHeight = simulator.workspaceMin.z - 0.02
        for (profile, told) in [(simulator, false), (tableBelowTheBox, true)] {
            let floor = gripperBox(profile).low.z
            bringUp(aids: true, arm: SIMD3(resetPose.x, resetPose.y, floor + 0.01), profile: profile)
            model.send(.holdArmStart)
            // 3 cm down (ARKit up is +y): 2 cm below the floor.
            for step in 1...3 {
                position = SIMD3(0, -0.01 * Float(step), 0)
                tick()
            }
            XCTAssertEqual(model.link.commandOutside, told ? .down : nil, "told: \(told)")
            XCTAssertEqual(sidesTold, told ? [.down] : [], "told: \(told)")
        }
    }

    /// The simulator's profile with every aid but the lowest cue. Its box floor still lies below its table.
    private var withoutTheLowestCue: RobotProfile {
        var profile = TestProfiles.so101
        profile.assist.guide?.lowestCue = false
        return profile
    }

    /// A floor below the table is left to the lowest rule only while that rule runs. Without it the model builds the
    /// work-area rule with the floor watched, so 2 cm below it is "Too low." as on a profile whose floor is above the
    /// table.
    func testWithTheLowestCueOffAFloorBelowTheTableIsTold() {
        let profile = withoutTheLowestCue
        XCTAssertEqual(profile.assist.guide?.workAreaWords, true, "the work-area words are on")
        XCTAssertLessThan(profile.workspaceMin.z, profile.tableHeight, "the floor is below the table")
        let floor = gripperBox(profile).low.z
        bringUp(aids: true, arm: SIMD3(resetPose.x, resetPose.y, floor + 0.01), profile: profile)
        model.send(.holdArmStart)
        // 3 cm down (ARKit up is +y): 2 cm below the floor.
        for step in 1...3 {
            position = SIMD3(0, -0.01 * Float(step), 0)
            tick()
        }
        XCTAssertEqual(model.link.commandOutside, .down)
        XCTAssertEqual(sidesTold, [.down])
        XCTAssertEqual(speech.spoken, ["Too low."])
    }

    /// The gripper link where the arm stands on the table: the pinch point at the profile's table height, below the
    /// reset pose.
    private var onTheTable: SIMD3<Double> {
        let profile = TestProfiles.so101
        return SIMD3(resetPose.x, resetPose.y, Double(profile.tableHeight - profile.toolOffset.z))
    }

    /// The arm stands on the table and the hand goes 6 cm down, a centimetre a tick (ARKit up is +y): the commanded
    /// point ends 6 cm below the arm, 1.2 cm under the simulator's box floor and inside every other face. The arm stays
    /// where it is, and the server sends a state every 198 ms for about 2 s, its label saying it clamps from
    /// `clampAtMs` on.
    private func pushIntoTheTable(clampAtMs: Int) {
        model.send(.holdArmStart)
        for step in 1...6 {
            position = SIMD3(0, -0.01 * Float(step), 0)
            tick()
        }
        transport.server("state", state(onTheTable, ik: "pose_tracking"))
        for elapsed in stride(from: 198, through: 1980, by: 198) {
            run(ticks: 6)
            transport.server("state", state(onTheTable, ik: elapsed >= clampAtMs ? "pose_clamped" : "pose_tracking"))
        }
        XCTAssertTrue(model.session.state.armMoving)
    }

    private var limits: [CueKey] {
        cues.filter { [.limit(.workspace), .limit(.blocked), .limit(.lowest)].contains($0) }
    }

    /// The simulator's box floor lies below its table: the table stops the arm before the commanded point can leave the
    /// box downward, and the lowest rule tells that push. Pushed into the table with the aids on, "Can't go lower." is
    /// the push's one cue: the server's clamp for the floor is not felt, whether it comes before the stall is told or
    /// after it, and no side is told.
    func testAPushIntoTheTableIsToldByTheLowestCueAlone() {
        for clampAtMs in [198, 1782] {
            bringUp(aids: true, arm: onTheTable)
            pushIntoTheTable(clampAtMs: clampAtMs)
            XCTAssertEqual(limits, [.limit(.lowest)], "clamp at \(clampAtMs) ms")
            XCTAssertEqual(sidesTold, [], "clamp at \(clampAtMs) ms")
            XCTAssertNil(model.link.commandOutside, "clamp at \(clampAtMs) ms")
            XCTAssertEqual(felt.felt, [.play(.go), .play(.end)], "clamp at \(clampAtMs) ms")
            XCTAssertEqual(speech.spoken, ["Can't go lower."], "clamp at \(clampAtMs) ms")
        }
    }

    /// The arm stands on the table and the hand goes 10 cm down, farther than the command may lead the arm: the link
    /// holds the command at that lead, and ends and re-sends the server hold to learn where the arm got to, the server
    /// answering each time with the arm still on the table, a state every 198 ms meanwhile. The push is still told by
    /// "Can't go lower.", once: only the pause of a re-sent start keeps the lowest rule from judging, not a command
    /// held at the lead, which is exactly a push into something.
    func testAPushIntoTheTableWithTheHandPastTheLeadIsStillTold() {
        bringUp(aids: true, arm: onTheTable)
        model.send(.holdArmStart)
        for step in 1...10 {
            position = SIMD3(0, -0.01 * Float(step), 0)
            tick()
        }
        XCTAssertTrue(model.catchingUp, "the command is held at the lead")
        var resyncs = 0
        for _ in 0..<15 {
            run(ticks: 6)
            if transport.types.last(where: { $0 != "test" }) == "pose_stop" {
                serverFinishesHold(armAt: onTheTable)
                resyncs += 1
            }
            transport.server("state", state(onTheTable, ik: "pose_tracking"))
        }
        XCTAssertGreaterThan(resyncs, 0, "the link ended the server hold to learn where the arm got to")
        XCTAssertTrue(model.session.state.armMoving)
        XCTAssertEqual(limits, [.limit(.lowest)])
        XCTAssertEqual(speech.spoken, ["Can't go lower."])
    }

    /// With the aids off the same pushes give version 1.0.1's cues: the server's clamp END, and "Blocked." first when
    /// the arm has stood still for a second before the clamp came.
    func testWithTheAidsOffAPushIntoTheTableGivesTheCuesOfOneZeroOne() {
        let pushes: [(clampAtMs: Int, heard: [CueKey], ends: Int, spoken: [String])] = [
            (198, [.limit(.workspace)], 1, []),
            (1782, [.limit(.blocked), .limit(.workspace)], 2, ["Blocked."]),
        ]
        for push in pushes {
            bringUp(aids: false, arm: onTheTable)
            pushIntoTheTable(clampAtMs: push.clampAtMs)
            XCTAssertEqual(limits, push.heard, "clamp at \(push.clampAtMs) ms")
            XCTAssertEqual(sidesTold, [], "clamp at \(push.clampAtMs) ms")
            XCTAssertEqual(felt.felt.filter { $0 == .play(.end) }.count, push.ends, "clamp at \(push.clampAtMs) ms")
            XCTAssertEqual(speech.spoken, push.spoken, "clamp at \(push.clampAtMs) ms")
        }
    }

    /// With every aid but the lowest cue, the floor is a face the work-area rule watches: the push into the table is
    /// told "Too low." as the commanded point goes past the floor, and the server's clamp for the floor is then not
    /// felt, as at any watched face. When the arm has stood still for a second before the server's clamp comes, version
    /// 1.0.1's "Blocked." plays as well: with the lowest cue off, that is the cue for a stall.
    func testWithTheLowestCueOffAPushIntoTheTableIsToldTooLow() {
        let pushes: [(clampAtMs: Int, heard: [CueKey], spoken: [String])] = [
            (198, [], ["Too low."]),
            (1782, [.limit(.blocked)], ["Too low.", "Blocked."]),
        ]
        for push in pushes {
            bringUp(aids: true, arm: onTheTable, profile: withoutTheLowestCue)
            pushIntoTheTable(clampAtMs: push.clampAtMs)
            XCTAssertEqual(sidesTold, [.down], "clamp at \(push.clampAtMs) ms")
            XCTAssertEqual(model.link.commandOutside, .down, "clamp at \(push.clampAtMs) ms")
            XCTAssertEqual(limits, push.heard, "clamp at \(push.clampAtMs) ms")
            XCTAssertEqual(speech.spoken, push.spoken, "clamp at \(push.clampAtMs) ms")
        }
    }

    /// The link leaves the server's clamp of a face the rule does not watch to the lowest rule only while that rule
    /// runs. Handed every aid but the lowest cue and the sides without the floor, nothing but the server tells a push
    /// into the table, so its clamp END plays, as in version 1.0.1.
    func testWithoutTheLowestRuleTheLinkStillPlaysTheClampOfAnUnwatchedFloor() {
        let pushes: [(clampAtMs: Int, heard: [CueKey], spoken: [String])] = [
            (198, [.limit(.workspace)], []),
            (1782, [.limit(.blocked), .limit(.workspace)], ["Blocked."]),
        ]
        for push in pushes {
            bringUp(aids: true, arm: onTheTable, profile: withoutTheLowestCue)
            var sides = Set(OperatorDirection.allCases)
            sides.remove(.down)
            model.link.guideAidsChanged(withoutTheLowestCue.assist.guide, gripperBox: gripperBox(), sides: sides)
            pushIntoTheTable(clampAtMs: push.clampAtMs)
            XCTAssertEqual(sidesTold, [], "clamp at \(push.clampAtMs) ms")
            XCTAssertEqual(limits, push.heard, "clamp at \(push.clampAtMs) ms")
            XCTAssertEqual(speech.spoken, push.spoken, "clamp at \(push.clampAtMs) ms")
        }
    }

    /// On a copy of the profile whose box floor is above the table, the floor is a face the work-area rule watches.
    /// Pushed slowly past it, the server's clamp is the crossing, as at any watched face: the rule tells "Too low." at
    /// the clamp and the server's END is left out.
    func testAClampPastAFloorAboveTheTableTellsTheSide() {
        var tableBelowTheBox = TestProfiles.so101
        tableBelowTheBox.tableHeight = tableBelowTheBox.workspaceMin.z - 0.02
        // 9.65 mm above the floor, so no step lands on the face or on the slack's boundary.
        let start = SIMD3(resetPose.x, resetPose.y, gripperBox(tableBelowTheBox).low.z + 0.00965)
        bringUp(aids: true, arm: start, profile: tableBelowTheBox)
        model.send(.holdArmStart)
        // Down a millimetre a tick (ARKit up is +y): after 11, 1.35 mm under the floor, inside the slack.
        for step in 1...11 {
            position = SIMD3(0, -0.001 * Float(step), 0)
            tick()
        }
        XCTAssertNil(model.link.commandOutside, "inside the slack")
        XCTAssertEqual(sidesTold, [])
        transport.server("state", state(start, ik: "pose_tracking"))
        transport.server("state", state(start, ik: "pose_clamped"))
        XCTAssertEqual(model.link.commandOutside, .down)
        XCTAssertEqual(sidesTold, [.down])
        XCTAssertFalse(cues.contains(.limit(.workspace)), "one crossing, one buzz")
        XCTAssertEqual(speech.spoken, ["Too low."])
    }

    /// A server whose box differs from the profile's: a push down that stays inside every face of the profile's box,
    /// clamped by that server, is past no face the rule knows, so the server's END is the push's cue, as in 1.0.1.
    func testAClampPastNoFaceOfTheProfilesBoxIsStillFelt() {
        bringUp(aids: true, arm: resetPose)
        model.send(.holdArmStart)
        // 3 cm down from the box's centre: 5 cm above its floor.
        for step in 1...3 {
            position = SIMD3(0, -0.01 * Float(step), 0)
            tick()
        }
        transport.server("state", state(resetPose, ik: "pose_tracking"))
        transport.server("state", state(resetPose, ik: "pose_clamped"))
        XCTAssertNil(model.link.commandOutside)
        XCTAssertEqual(sidesTold, [])
        XCTAssertEqual(limits, [.limit(.workspace)])
        XCTAssertEqual(felt.felt.filter { $0 == .play(.end) }.count, 1)
    }

    /// A resync's pause is not a stall. The arm, 6 cm above the reset pose, comes down after a hand that went 12 cm
    /// down; 1.5 s into the server hold the link ends it to learn where the arm got to, and the server's answer is held
    /// back for 1.3 s while states every 198 ms report the arm standing still in the air. Then the server finishes the
    /// hold, the start is re-sent and the arm goes on down. With the aids on nothing is told for the pause and no
    /// lowest height is kept; with them off the same pause gives version 1.0.1's "Blocked.".
    func testAResyncsPauseIsNotTakenForTheLowestHeight() {
        for aids in [true, false] {
            var arm = resetPose + SIMD3(0, 0, 0.06)
            bringUp(aids: aids, arm: arm)
            model.send(.holdArmStart)
            for step in 1...12 {
                position = SIMD3(0, -0.01 * Float(step), 0)
                tick()
            }
            var ticks = 0
            while transport.types.last(where: { $0 != "test" }) != "pose_stop", ticks < 100 {
                run(ticks: 1)
                ticks += 1
                if ticks % 6 == 0 {
                    arm.z -= 0.005
                    transport.server("state", state(arm, ik: "pose_tracking"))
                }
            }
            XCTAssertEqual(transport.types.last { $0 != "test" }, "pose_stop", "aids \(aids): the link asks")
            // These states stand in for the listening connection's: with no final ack they do not end the resync.
            for step in 1...39 {
                run(ticks: 1)
                if step % 6 == 0 { transport.server("state", state(arm, ik: "ok")) }
            }
            serverFinishesHold(armAt: arm)
            XCTAssertEqual(transport.types.last, "pose_start", "aids \(aids): the start is re-sent")
            for _ in 0..<5 {
                run(ticks: 6)
                arm.z -= 0.006
                transport.server("state", state(arm, ik: "pose_tracking"))
            }
            XCTAssertTrue(model.session.state.armMoving, "aids \(aids): the operator still holds")
            if aids {
                XCTAssertEqual(limits, [], "nothing for the pause")
                XCTAssertFalse(speech.spoken.contains("Can't go lower."), "\(speech.spoken)")
                XCTAssertNil(model.link.lowestSeen, "no height kept in the air")
                XCTAssertNil(model.link.lowestPinchSeen)
            } else {
                XCTAssertEqual(limits, [.limit(.blocked)], "version 1.0.1's")
                XCTAssertEqual(speech.spoken, ["Blocked."])
            }
        }
    }

    /// The side is read only while a translation is commanded: never between holds, and not at a new hold's start
    /// before its first command, so the guide's line cannot show the last hold's side. A new hold tells it again.
    func testTheSideIsReadOnlyWhileATranslationIsCommanded() {
        let start = SIMD3(resetPose.x, gripperBox().low.y + 0.01, resetPose.z)
        bringUp(aids: true, arm: start)
        XCTAssertNil(model.link.commandOutside, "no hold")
        model.send(.holdArmStart)
        handForward(3)
        XCTAssertEqual(model.link.commandOutside, .forward)
        model.send(.holdArmEnd)
        XCTAssertNil(model.link.commandOutside, "the hold ended")
        serverFinishesHold(armAt: start)
        run(ticks: 50)
        position = .zero
        model.send(.holdArmStart)
        XCTAssertEqual(transport.types.last, "pose_start")
        XCTAssertNil(model.link.commandOutside, "a new hold, before its first command")
        tick()
        XCTAssertNil(model.link.commandOutside, "back inside")
        handForward(3)
        XCTAssertEqual(model.link.commandOutside, .forward)
        XCTAssertEqual(sidesTold, [.forward, .forward], "told again in the new hold")
    }

    /// Inside one press the link ends the server hold and re-sends the start to learn where the arm got to. That
    /// restart is not a new press: the side already told is not told again while the commanded point stays past its
    /// face, and the 1.5 s the rule keeps between two cues of one press still holds back a crossing of another side
    /// right after the restart; that side is told on the first tick after those 1.5 s.
    func testAResyncInsideAPressKeepsTheGap() throws {
        let box = gripperBox()
        // 1 cm inside the right face (base −x) and 7.5 cm inside the forward face (base −y).
        let start = SIMD3(box.low.x + 0.01, box.low.y + 0.075, resetPose.z)
        bringUp(aids: true, arm: start)
        model.send(.holdArmStart)
        // The hand rests until late in the server hold, then goes 10 cm forward, a centimetre a tick (ARKit forward is
        // −z). A server hold asks for at most 8 cm, which takes the commanded point 5 mm past the forward face.
        run(ticks: 36)
        var forwardToldAt: Int?
        for step in 1...10 {
            position = SIMD3(0, 0, -0.01 * Float(step))
            tick()
            if forwardToldAt == nil, !sidesTold.isEmpty { forwardToldAt = clock }
        }
        XCTAssertEqual(sidesTold, [.forward])
        let toldAt = try XCTUnwrap(forwardToldAt)
        // 1.5 s into the server hold, with the hand asking for more than it may, the link ends that hold.
        XCTAssertEqual(transport.types.last { $0 != "test" }, "pose_stop", "the link asks where the arm got to")
        XCTAssertTrue(model.session.state.armMoving, "the operator still holds")
        // The server reports the arm at the face, and the link re-sends the start for the last 2.5 cm, past it.
        serverFinishesHold(armAt: SIMD3(start.x, box.low.y, start.z))
        XCTAssertEqual(transport.types.last, "pose_start", "the start is re-sent")
        tick()
        XCTAssertEqual(model.link.commandOutside, .forward, "still past the forward face")
        XCTAssertEqual(sidesTold, [.forward], "the restart is not a new press: forward is not told again")
        // Right after the restart the hand goes 5 cm right (the operator's right is base −x), a centimetre a tick: the
        // commanded point ends 4 cm past the right face, farther than it is past the forward one.
        for step in 1...5 {
            position = SIMD3(0.01 * Float(step), 0, -0.1)
            tick()
        }
        XCTAssertEqual(model.link.commandOutside, .right, "the line shows the new side at once")
        XCTAssertLessThan(clock - toldAt, WorkAreaCue.minimumGapMs)
        XCTAssertEqual(sidesTold, [.forward], "held back by the gap since the forward cue")
        var rightToldAt: Int?
        while rightToldAt == nil, clock - toldAt < 2 * WorkAreaCue.minimumGapMs {
            run(ticks: 1)
            if sidesTold.count > 1 { rightToldAt = clock }
        }
        XCTAssertEqual(sidesTold, [.forward, .right])
        let rightAt = try XCTUnwrap(rightToldAt)
        XCTAssertGreaterThanOrEqual(rightAt - toldAt, WorkAreaCue.minimumGapMs, "not before the gap is over")
        XCTAssertLessThan(rightAt - toldAt, WorkAreaCue.minimumGapMs + 33, "on the first tick after it")
        XCTAssertEqual(transport.types.filter { $0 == "pose_start" }.count, 2, "one press, one re-sent start")
        XCTAssertTrue(model.session.state.armMoving, "the operator still holds")
    }

    /// The same restart with the commanded point kept past the forward face alone, for longer than the 1.5 s the rule
    /// keeps between two cues: forward is told once in the press. The restart does not arm a side already told, so
    /// once the gap is over there is still nothing to tell while the point stays past that face.
    func testAResyncInsideAPressDoesNotTellTheSameSideAgain() throws {
        let box = gripperBox()
        // 7.5 cm inside the forward face (base −y), half way across and half way up.
        let start = SIMD3(resetPose.x, box.low.y + 0.075, resetPose.z)
        bringUp(aids: true, arm: start)
        model.send(.holdArmStart)
        // The hand rests until late in the server hold, then goes 10 cm forward, a centimetre a tick (ARKit forward is
        // −z). A server hold asks for at most 8 cm, which takes the commanded point 5 mm past the forward face.
        run(ticks: 36)
        var forwardToldAt: Int?
        for step in 1...10 {
            position = SIMD3(0, 0, -0.01 * Float(step))
            tick()
            if forwardToldAt == nil, !sidesTold.isEmpty { forwardToldAt = clock }
        }
        XCTAssertEqual(sidesTold, [.forward])
        let toldAt = try XCTUnwrap(forwardToldAt)
        XCTAssertEqual(transport.types.last { $0 != "test" }, "pose_stop", "the link asks where the arm got to")
        // The server reports the arm at the face, and the link re-sends the start for the last 2.5 cm, past it.
        serverFinishesHold(armAt: SIMD3(start.x, box.low.y, start.z))
        XCTAssertEqual(transport.types.last, "pose_start", "the start is re-sent")
        // The hand stays: until twice the gap since forward was told, the commanded point is past the forward face by
        // more than the slack and inside every other face.
        while clock - toldAt < 2 * WorkAreaCue.minimumGapMs {
            run(ticks: 1)
            let point = SIMD3<Double>(try XCTUnwrap(model.link.commandedArm))
            let since = clock - toldAt
            XCTAssertLessThan(point.y, box.low.y - WorkAreaCue.slackMeters, "past the forward face, at \(since) ms")
            XCTAssertTrue(point.x > box.low.x && point.x < box.high.x, "inside across, at \(since) ms")
            XCTAssertTrue(point.z > box.low.z && point.z < box.high.z, "inside in height, at \(since) ms")
            XCTAssertEqual(model.link.commandOutside, .forward, "at \(since) ms")
        }
        XCTAssertEqual(sidesTold, [.forward], "one press: forward is told once")
        XCTAssertEqual(transport.types.filter { $0 == "pose_start" }.count, 2, "one press, one re-sent start")
        XCTAssertTrue(model.session.state.armMoving, "the operator still holds")
    }

    /// The guide draws the commanded ring at the commanded gripper-link point plus the measured offset, and the box at
    /// the profile's box moved by that offset less the profile's tool offset. The link judges the commanded
    /// gripper-link point against the profile's box less its tool offset. So with a tool point the server reports,
    /// whatever offset it measures, the side the link tells is the side the drawn ring is past the drawn box on, by
    /// more than the slack.
    func testTheSideToldIsTheSideTheDrawnRingIsPastTheDrawnBoxOn() throws {
        let box = gripperBox()
        // 9.65 mm inside the right face (base −x), so no step lands on the slack's own boundary.
        let start = SIMD3(box.low.x + 0.00965, resetPose.y, resetPose.z)
        let measured = SIMD3(0.012, -0.03, -0.095)
        bringUp(aids: true, arm: start, tool: start + measured)
        model.send(.holdArmStart)
        var told: [OperatorDirection?] = []
        // Right a millimetre a tick (the operator's right is base −x), to about 10 mm past the face.
        for step in 1...20 {
            position = SIMD3(0.001 * Float(step), 0, 0)
            tick()
            model.inputsChanged()
            let ring = SIMD3<Double>(try XCTUnwrap(model.operating.arm?.commanded))
            let guide = try XCTUnwrap(model.operating.guide)
            var farthest: (side: OperatorDirection, by: Double)?
            for side in OperatorDirection.allCases where side != .down {
                let way = side.baseVector
                let by = simd_dot(ring, way) - max(simd_dot(guide.workBoxLow, way), simd_dot(guide.workBoxHigh, way))
                if by > (farthest?.by ?? -.infinity) { farthest = (side, by) }
            }
            let drawn = farthest.flatMap { $0.by > WorkAreaCue.slackMeters ? $0.side : nil }
            XCTAssertEqual(model.link.commandOutside, drawn, "step \(step)")
            told.append(model.link.commandOutside)
        }
        XCTAssertEqual(told.compactMap { $0 }.count, 9, "from 12 mm on, 2.35 mm past the face and more")
        XCTAssertEqual(Set(told.compactMap { $0 }), [.right])
        XCTAssertEqual(sidesTold, [.right])
    }

    private func wait(_ seconds: TimeInterval, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if done() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return done()
    }

    /// Against the server model over a real socket: from the reset pose the jaws reach the table a little under 3 cm
    /// down. The hand asks for 5 cm down, and the arm stands on the table. With the aids on that is "Can't go lower.",
    /// the lowest heights are where the arm and the jaws stand, and the guide's line lies at the height of the pinch
    /// point the server reports there; with them off it is version 1.0.1's "Blocked." and no height.
    func testAgainstTheServerModelsTableTheArmCannotGoLower() throws {
        for aids in [true, false] {
            let server = LocalTeleopServer()
            try server.start()
            defer { server.stop() }
            var hand = SIMD3<Float>.zero
            let model = AppModel(
                start: .s1, haptics: NoHaptics(), pose: { TestPose.portrait(at: hand) }, liveLink: true,
                assistOn: aids, lockChoice: .off)
            model.session.state.serverAddress = server.address
            model.connect()
            XCTAssertTrue(wait(TestWaits.linkUp, until: { model.session.state.connected }), "aids \(aids)")
            // During a hold only the listening connection hears where the arm is.
            XCTAssertTrue(wait(TestWaits.linkUp, until: { model.link.observerUp }), "aids \(aids)")
            model.send(.holdArmStart)
            // 5 cm down (ARKit up is +y) over 0.75 s.
            for step in 1...25 {
                hand = SIMD3(0, -0.002 * Float(step), 0)
                _ = wait(0.03, until: { false })
            }
            let heard: CueKey = aids ? .limit(.lowest) : .limit(.blocked)
            let notHeard: CueKey = aids ? .limit(.blocked) : .limit(.lowest)
            XCTAssertTrue(
                wait(5, until: { model.cueLog.contains { $0.event == heard } }),
                "aids \(aids): \(model.cueLog.map(\.event))")
            XCTAssertFalse(model.cueLog.contains { $0.event == notHeard }, "aids \(aids)")
            XCTAssertEqual(model.cueLog.filter { $0.event == heard }.count, 1, "aids \(aids)")
            if aids {
                let lowest = try XCTUnwrap(model.link.lowestSeen)
                XCTAssertEqual(lowest, server.inspect { $0.world.arm.z }, accuracy: 0.002, "where the arm stands")
                let pinchZ = server.inspect { ($0.world.arm + $0.config.toolOffset).z }
                let lowestPinch = try XCTUnwrap(model.link.lowestPinchSeen)
                XCTAssertEqual(lowestPinch, pinchZ, accuracy: 0.002, "where the jaws stand")
                XCTAssertTrue(wait(2, until: { model.operating.guide?.lowestY != nil }), "the line is drawn")
                let picture = try XCTUnwrap(model.operating.guide)
                let y = try XCTUnwrap(picture.lowestY)
                let range = picture.projection.height
                let lineZ = range.lowerBound + (1 - y) * (range.upperBound - range.lowerBound)
                XCTAssertEqual(lineZ, pinchZ, accuracy: 0.002, "the line at the jaws' height on the table")
            } else {
                XCTAssertNil(model.link.lowestSeen)
                XCTAssertNil(model.link.lowestPinchSeen)
                XCTAssertNil(model.operating.guide?.lowestY)
            }
            model.send(.holdArmEnd)
        }
    }

    /// The model hands the link its aids at launch and at every change of the switch.
    func testTheSwitchHandsTheLinkItsAids() {
        let start = SIMD3(resetPose.x, gripperBox().low.y + 0.01, resetPose.z)
        bringUp(aids: true, arm: start)
        model.assistOn = false
        model.send(.holdArmStart)
        handForward(3)
        XCTAssertNil(model.link.commandOutside, "off")
        model.send(.holdArmEnd)
        serverFinishesHold(armAt: start)
        model.assistOn = true
        position = .zero
        model.send(.holdArmStart)
        handForward(3)
        XCTAssertEqual(model.link.commandOutside, .forward, "on again")
        XCTAssertEqual(sidesTold, [.forward])
    }
}
