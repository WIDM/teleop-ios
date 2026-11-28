import simd
import TeleopCore
import TeleopServerHost
import TeleopServerModel
import XCTest
@testable import Teleop

/// The direction check (`DirectionCheck`) against the in-app server model, for the SO-101 and bench arm B, and its
/// judgement on moves made up by hand. `OperatorLiveTests` runs the same check against a real server.
final class DirectionCheckTests: XCTestCase {
    private var server: LocalTeleopServer!
    private var hand: ScriptedOperator!

    override func tearDown() {
        hand?.finish()
        if hand != nil, let server {
            XCTAssertTrue(server.waitForTheAppsSocketsToClose(), "the server still holds \(server.openSockets) sockets")
        }
        hand = nil
        server?.stop()
        server = nil
    }

    /// The server model for `profile`, and an app that believes `appProfile` (the same unless a test plants a fault).
    /// `reportsToolPoint` false is a server whose states carry no `tool_pos`. `makeTransport` stands between the app and
    /// the server, to model a server whose link frame the profile cannot say.
    private func start(
        serverFor profile: RobotProfile, appProfile: RobotProfile? = nil, reportsToolPoint: Bool = true,
        makeTransport: ((URL) -> LinkTransport)? = nil
    ) throws {
        let config: ServerModelConfig
        if profile.gripper.unit == .mm {
            config = try BenchArmB.config(for: profile, reportsToolPoint: reportsToolPoint)
        } else {
            config = try .s4Simulator(stepsPerSecond: 60, reportsToolPoint: reportsToolPoint)
                .settingFrames(from: profile.frames)
        }
        server = LocalTeleopServer(config: config)
        try server.start()
        hand = ScriptedOperator(
            address: server.address, mode: .buttons, smoothing: 0.3, pace: 0.3, profile: appProfile ?? profile,
            makeTransport: makeTransport)
        XCTAssertTrue(hand.connect(within: TestWaits.linkUp), "could not connect to the local server")
        _ = try XCTUnwrap(hand.model.link.armPosition, "the local server reported no arm position")
    }

    private func check(
        _ profile: RobotProfile, as app: RobotProfile? = nil, reportsToolPoint: Bool = true,
        makeTransport: ((URL) -> LinkTransport)? = nil
    ) throws -> DirectionCheck.Result {
        try start(
            serverFor: profile, appProfile: app, reportsToolPoint: reportsToolPoint, makeTransport: makeTransport)
        return try XCTUnwrap(hand.directionCheck(), "the check could not read the arm")
    }

    private func finishRun() {
        hand.finish()
        hand = nil
        server.stop()
        server = nil
    }

    // MARK: Against the server model

    func testEveryDirectionGoesTheNamedWayForEachProfile() throws {
        for (name, profile) in [("SO-101", TestProfiles.so101), ("bench arm B", TestProfiles.benchB)] {
            let result = try check(profile)
            XCTAssertEqual(result.faults, [], name)
            XCTAssertEqual(
                result.moves.map(\.direction), OperatorDirection.allCases, "all six directions, in this order")
            XCTAssertEqual(result.warnings, [], name)
            finishRun()
        }
    }

    /// The check reads the point the app drives: `tool_pos` where the server has a tool calibration (the app then
    /// drives the tool point), else `ee_pos`; and passes on both paths. The in-app server model reports `tool_pos` in
    /// its states but offers no calibration, so the tool path is the same server told to the app as calibrated, with the tool point's fields taken off the start.
    func testTheCheckReadsTheControlledPointOnBothPaths() throws {
        for (name, profile) in [("SO-101", TestProfiles.so101), ("bench arm B", TestProfiles.benchB)] {
            for calibrated in [true, false] {
                let result = try check(
                    profile, makeTransport: calibrated ? { ToolCalibratedTransport(url: $0) } : nil)
                XCTAssertEqual(result.faults, [], "\(name), calibrated \(calibrated)")
                XCTAssertEqual(result.moves.count, 6, "\(name), calibrated \(calibrated)")
                XCTAssertTrue(
                    result.moves.allSatisfy { $0.point == (calibrated ? .tool : .gripperLink) },
                    "\(name), calibrated \(calibrated): \(result.moves.map(\.point))")
                finishRun()
            }
        }
    }

    /// B's file with the sign of the link's z written the wrong way: "up" goes the other way, the message names the
    /// direction and the axis, and the check stops there: "down" is never pressed.
    func testAPlantedWrongSignInBsFileFailsTheCheckAndStops() throws {
        var wrong = TestProfiles.benchB
        wrong.frames.linkSigns.z = -wrong.frames.linkSigns.z
        let result = try check(TestProfiles.benchB, as: wrong)
        XCTAssertEqual(result.faults.count, 1, "\(result.faults)")
        let up = try XCTUnwrap(result.faults.first, "\(result.faults)")
        XCTAssertTrue(up.hasPrefix("up:") && up.contains("wrong way"), up)
        XCTAssertTrue(up.contains("server.link_signs") && !up.contains("robot.directions"), up)
        XCTAssertTrue(up.contains("base -z") || up.contains("base +z"), "the sentence names the axis: \(up)")
        XCTAssertEqual(result.moves.last?.direction, .up, "stopped at the first bad step")
        XCTAssertEqual(result.moves.count, 5, "forward, back, left, right, up")
    }

    /// The app's profile has the wrong sign for the link's x: left is the first direction along it, fails, and nothing
    /// after it is pressed.
    func testAPlantedWrongLinkSignOnAnotherAxisIsNamed() throws {
        var wrong = TestProfiles.so101
        wrong.frames.linkSigns.x = -wrong.frames.linkSigns.x
        let result = try check(TestProfiles.so101, as: wrong)
        XCTAssertEqual(result.faults.count, 1, "\(result.faults)")
        XCTAssertTrue(result.faults[0].hasPrefix("left:"), "\(result.faults)")
        XCTAssertEqual(result.moves.map(\.direction), [.forward, .back, .left])
    }

    /// A server whose link frame swaps x and y, which a profile cannot say: forward goes along the other axis, the
    /// sentence names both and says the arm's server needs code.
    func testASwappedServerFrameIsNamedEndToEnd() throws {
        let result = try check(TestProfiles.so101, makeTransport: { SwappingTransport(url: $0) })
        XCTAssertEqual(result.faults.count, 1, "\(result.faults)")
        let forward = try XCTUnwrap(result.faults.first)
        XCTAssertTrue(forward.hasPrefix("forward:") && forward.contains("instead of base -y"), forward)
        XCTAssertTrue(forward.contains("along base +x") || forward.contains("along base -x"), forward)
        XCTAssertTrue(forward.contains("needs code") && !forward.contains("robot.directions"), forward)
        XCTAssertEqual(result.moves.map(\.direction), [.forward], "stopped at the first bad step")
    }

    /// What the check cannot see: a profile that names forward as the wrong way along its axis. The app sends what the
    /// profile says, so the arm goes there and the read-back agrees: no fault. The plausibility warning is what
    /// notices: the work box then lies behind the base.
    func testTheReadBackCannotTellWhichWayForwardPointsButThePlausibilityWarningCan() throws {
        var wrong = TestProfiles.so101
        wrong.frames.forward = wrong.frames.forward.reversed
        wrong.frames.left = wrong.frames.left.reversed
        let result = try check(TestProfiles.so101, as: wrong)
        XCTAssertEqual(result.faults, [])
        XCTAssertEqual(result.warnings.count, 1, "\(result.warnings)")
        XCTAssertTrue(result.warnings[0].hasPrefix("forward is base +y"), result.warnings[0])
    }

    // MARK: The judgement

    private func fault(_ direction: OperatorDirection, expected: SignedAxis, _ cm: SIMD3<Double>) -> String? {
        DirectionCheck.fault(.init(direction: direction, expected: expected, delta: cm / 100))
    }

    func testJudgement() throws {
        let forward = SignedAxis(.y, -1)
        XCTAssertNil(fault(.forward, expected: forward, SIMD3(0, -1, 0)))
        XCTAssertNil(fault(.forward, expected: forward, SIMD3(0.1, -0.8, 0.2)), "a little off-axis is allowed")
        XCTAssertNil(fault(.forward, expected: forward, SIMD3(0, -0.6, 0)), "6 mm of 10 is still along it")
        XCTAssertNil(fault(.forward, expected: forward, SIMD3(0.3, -0.8, 0.2)), "24 degrees off is within 30")

        let wrongWay = try XCTUnwrap(fault(.forward, expected: forward, SIMD3(0, 1, 0)))
        XCTAssertTrue(wrongWay.hasPrefix("forward:") && wrongWay.contains("wrong way"), wrongWay)
        XCTAssertTrue(wrongWay.contains("base +y") && wrongWay.contains("server.link_signs"), wrongWay)
        XCTAssertFalse(wrongWay.contains("robot.directions"), "only a link sign can send the arm the other way")

        let other = try XCTUnwrap(fault(.forward, expected: forward, SIMD3(1, 0, 0)))
        XCTAssertTrue(other.hasPrefix("forward:"), other)
        XCTAssertTrue(other.contains("along base +x") && other.contains("instead"), other)
        XCTAssertTrue(other.contains("needs code") && !other.contains("robot.directions"), other)

        let still = try XCTUnwrap(fault(.forward, expected: forward, SIMD3(0, -0.1, 0)))
        XCTAssertTrue(still.contains("did not move"), still)

        let notStarted = try XCTUnwrap(
            DirectionCheck.fault(.init(direction: .left, expected: SignedAxis(.x, 1), delta: .zero, started: false)))
        XCTAssertTrue(notStarted.hasPrefix("left:") && notStarted.contains("did not start"), notStarted)

        let sideways = try XCTUnwrap(fault(.up, expected: SignedAxis(.z, 1), SIMD3(0.8, 0, 1)))
        XCTAssertTrue(sideways.hasPrefix("up:") && sideways.contains("also") && sideways.contains("base +x"), sideways)
    }

    /// A largest move on another axis does not prove a swapped server frame: 8 mm along x with 9 mm of sag in z lands
    /// there too. The sentence names the swapped frame as one cause beside a limit, a sag and a path.
    func testAMoveOnAnotherAxisNamesASwappedFrameAsOneCauseOfSeveral() throws {
        let sag = try XCTUnwrap(fault(.left, expected: SignedAxis(.x, 1), SIMD3(0.8, 0, -0.9)))
        XCTAssertTrue(sag.hasPrefix("left:") && sag.contains("along base -z") && sag.contains("instead"), sag)
        XCTAssertTrue(sag.contains("One cause is") && sag.contains("swapped"), sag)
        XCTAssertTrue(sag.contains("limit") && sag.contains("sag") && sag.contains("path"), sag)
        XCTAssertTrue(sag.contains("needs code") && !sag.contains("robot.directions"), sag)
    }

    /// Direction is judged by angle; a short or long move is a warning and never a fault.
    func testDistanceIsAWarningNotAFault() throws {
        let up = SignedAxis(.z, 1)
        let move = { (cm: SIMD3<Double>) in DirectionCheck.Move(direction: .up, expected: up, delta: cm / 100) }
        XCTAssertNil(DirectionCheck.fault(move(SIMD3(0, 0, 0.3))), "3 mm the right way is not a sign fault")
        let short = try XCTUnwrap(DirectionCheck.warning(move(SIMD3(0, 0, 0.3))))
        XCTAssertTrue(short.hasPrefix("up:") && short.contains("fine_mps") && short.contains("Lag"), short)
        XCTAssertNil(DirectionCheck.fault(move(SIMD3(0, 0, 3))), "3 cm the right way is not a sign fault")
        XCTAssertNotNil(DirectionCheck.warning(move(SIMD3(0, 0, 3))))
        XCTAssertNil(DirectionCheck.warning(move(SIMD3(0, 0, 1))))
        XCTAssertNotNil(DirectionCheck.fault(move(SIMD3(0, 0, 0.1))), "under 2 mm is no move")
        XCTAssertNil(DirectionCheck.warning(move(SIMD3(0, 0, -1))), "a wrong-way move is a fault, not a warning")
    }

    /// The limit of the forward warning, pinned. Bench arm B hangs over its work area: the box's centre is 2.8 cm
    /// behind the base along forward, inside the dead zone of a quarter of the box's width (4 cm), so neither B nor B
    /// with forward and left reversed is warned. The warning helps for an arm whose work area lies clearly in front;
    /// a person watching the arm is still required (docs/PROFILE.md, "The work box and forward").
    func testForwardWarningDoesNotFireForBenchArmBInEitherDirection() throws {
        let b = TestProfiles.benchB
        let low = SIMD3<Double>(b.workspaceMin), high = SIMD3<Double>(b.workspaceMax)
        let centre = b.frames.forward.component(of: (low + high) / 2)
        let width = high[b.frames.forward.axis.index] - low[b.frames.forward.axis.index]
        XCTAssertEqual(centre, -0.028, accuracy: 1e-9, "B's box centre is 2.8 cm behind the base along forward")
        XCTAssertEqual(DirectionCheck.behindShare * width, 0.04, accuracy: 1e-9, "against a dead zone of 4 cm")
        XCTAssertNil(DirectionCheck.forwardWarning(b))
        var reversed = b
        reversed.frames.forward = reversed.frames.forward.reversed
        reversed.frames.left = reversed.frames.left.reversed
        XCTAssertNil(DirectionCheck.forwardWarning(reversed), "forward reversed on B is not seen by the warning")
    }

    /// The forward plausibility rule: the work box is not clearly behind the base along forward.
    func testForwardPlausibility() {
        XCTAssertNil(DirectionCheck.forwardWarning(TestProfiles.so101))
        XCTAssertNil(DirectionCheck.forwardWarning(TestProfiles.benchB), "an arm hung over its work area")
        var wrong = TestProfiles.so101
        wrong.frames.forward = wrong.frames.forward.reversed
        wrong.frames.left = wrong.frames.left.reversed
        let warning = DirectionCheck.forwardWarning(wrong)
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.contains("robot.directions") == true, warning ?? "")
    }
}

/// The app's socket through a server whose link frame has x and y swapped: every `pose_update` has the first two
/// numbers of its offset exchanged on the way.
private final class SwappingTransport: LinkTransport {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    private let socket: WebSocketTransport

    init(url: URL) {
        socket = WebSocketTransport(url: url)
        socket.onText = { [weak self] in self?.onText?($0) }
        socket.onClose = { [weak self] in self?.onClose?() }
    }

    func open() { socket.open() }
    func close() { socket.close() }
    func send(_ text: String) {
        guard var message = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
            message["type"] as? String == "pose_update", var payload = message["payload"] as? [String: Any],
            var offset = payload["p_rel_m"] as? [Double], offset.count == 3
        else { return socket.send(text) }
        offset.swapAt(0, 1)
        payload["p_rel_m"] = offset
        message["payload"] = payload
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]),
            let swapped = String(data: data, encoding: .utf8)
        else { return socket.send(text) }
        socket.send(swapped)
    }
}

/// The app's socket through a server that also tells the app it has a tool calibration, so the app drives the tool
/// point (`tool_pos`) as it does against the simulator: the welcome gains `control_points` and `tool_calibration_id`.
private final class ToolCalibratedTransport: LinkTransport {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    private let socket: WebSocketTransport

    init(url: URL) {
        socket = WebSocketTransport(url: url)
        socket.onText = { [weak self] text in
            guard var message = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                message["type"] as? String == "welcome", var payload = message["payload"] as? [String: Any]
            else { return self?.onText?(text) ?? () }
            payload["control_points"] = ["link_origin", "tool"]
            payload["tool_calibration_id"] = "direction-check-tool"
            message["payload"] = payload
            let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
            self?.onText?(data.flatMap { String(data: $0, encoding: .utf8) } ?? text)
        }
        socket.onClose = { [weak self] in self?.onClose?() }
    }

    func open() { socket.open() }
    func close() { socket.close() }
    /// The in-app model moves the gripper link by the offset and knows no tool control point, so the two fields that
    /// name the tool point leave the `pose_start`; the wrist stays put, so the tool point moves with the link.
    func send(_ text: String) {
        guard var message = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
            message["type"] as? String == "pose_start", var payload = message["payload"] as? [String: Any],
            payload["control_point"] != nil
        else { return socket.send(text) }
        payload["control_point"] = nil
        payload["calibration_id"] = nil
        message["payload"] = payload
        let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        socket.send(data.flatMap { String(data: $0, encoding: .utf8) } ?? text)
    }
}
