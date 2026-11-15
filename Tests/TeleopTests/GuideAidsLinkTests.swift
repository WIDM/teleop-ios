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
/// table stops the arm before is not told; the side is read only while a translation is commanded; the switch reaches
/// the link. Against the server model, an arm that cannot go lower says so. With the aids off the cues are version
/// 1.0.1's.
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
        aids: Bool, arm: SIMD3<Double>, tool: SIMD3<Double>? = nil, profile: RobotProfile = .so101Simulator
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
    private func gripperBox(_ profile: RobotProfile = .so101Simulator) -> (low: SIMD3<Double>, high: SIMD3<Double>) {
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
        let simulator = RobotProfile.so101Simulator
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
            XCTAssertTrue(wait(3, until: { model.session.state.connected }), "aids \(aids)")
            // During a hold only the listening connection hears where the arm is.
            XCTAssertTrue(wait(3, until: { model.link.observerUp }), "aids \(aids)")
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
