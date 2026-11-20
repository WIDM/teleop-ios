import simd
import TeleopCore
import XCTest
@testable import Teleop

private final class JawsTransport: LinkTransport {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    var sent: [[String: Any]] = []
    var now: () -> Int = { 0 }
    func open() {}
    func close() {}
    func send(_ text: String) {
        sent.append(try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])
    }
    func receive(_ type: String, _ payload: [String: Any] = [:]) {
        let envelope: [String: Any] = ["v": 1, "type": type, "ts": now(), "seq": 0, "payload": payload]
        onText?(String(data: try! JSONSerialization.data(withJSONObject: envelope), encoding: .utf8)!)
    }
    func messages(_ type: String) -> [[String: Any]] { sent.filter { $0["type"] as? String == type } }
}

/// The build 32 trial of 2026-11-20: the server starts every episode with the jaws closed, the operator moved next to
/// the cube and only then opened them, and the opening jaw swept the cube away. On the first translation of an episode
/// that starts with the jaws still closed, the screen shows, once, to open them before moving in. It is shown only:
/// nothing is felt or spoken for it, and the cue stream is what it would be without it. The move goes out all the
/// same.
final class OpenJawsFirstTests: XCTestCase {
    private var model: AppModel!
    private var wire: JawsTransport!
    private var speech: SpySpeech!
    /// How many times the screen has been told to show the reminder in this test.
    private var reminders = 0
    private var lastShownAtMs: Int?
    private var clock = 10_000
    private var saved: [String: Any] = [:]
    private var savedLanguage = L10n.language
    private let keys = [AppModel.controlModeKey, AppModel.taskAidKey, AppModel.assistKey, AppModel.lockChoiceKey]

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.language
        L10n.language = .en
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
    }

    override func tearDown() {
        model = nil
        for key in keys { UserDefaults.standard.set(saved[key], forKey: key) }
        L10n.language = savedLanguage
        super.tearDown()
    }

    /// Connected with the precision panel open, the jaws reported as the server starts an episode: `closed`, 0 degrees.
    private func bringUp(episode: Int? = 1) {
        clock = 10_000
        UserDefaults.standard.set(false, forKey: AppModel.taskAidKey)
        wire = JawsTransport()
        wire.now = { [unowned self] in clock }
        speech = SpySpeech()
        reminders = 0
        lastShownAtMs = nil
        model = AppModel(
            start: .p4, haptics: NoHaptics(), sounds: SpySounds(), speech: speech,
            pose: { TestPose.portrait }, liveLink: true,
            makeTransport: { [unowned self] _ in wire }, makeObserverTransport: { _ in JawsTransport() },
            nowMs: { [unowned self] in clock }, inputClock: { [unowned self] in Double(clock) / 1000 },
            assistOn: false, lockChoice: .off, voiceActionsPrototype: false)
        model.controlMode = .screenTurns
        model.session.state.setSmoothing(0)
        model.session.state.serverAddress = "127.0.0.1:8765"
        model.connect()
        welcome()
        model.surfaceChanged(width: 375, height: 667, safeTop: 20, safeBottom: 0)
        model.setPrecisionPanelOpen(true)
    }

    private func welcome() {
        wire.receive("welcome", ["control_points": ["link_origin", "tool"], "tool_calibration_id": "test-tool"])
        state(episode: 1)
    }

    private func state(
        jaws: String? = "closed", degrees: Double? = 0, episode: Int? = nil, estop: Bool = false, ik: String = "ok"
    ) {
        clock += 50
        var payload: [String: Any] = [
            "estop": estop, "ik": ik, "ee_pos": [0, -0.14, 0.16], "tool_pos": [0.01, -0.17, 0.07],
        ]
        if let jaws { payload["gripper"] = jaws }
        if let degrees { payload["gripper_deg"] = degrees }
        if let episode { payload["episode"] = episode }
        wire.receive("state", payload)
    }

    /// Counts a new showing of the reminder, read from the model's fact.
    private func noteShown() {
        guard let shown = model.lastOpenJawsFirstAtMs, shown != lastShownAtMs else { return }
        lastShownAtMs = shown
        reminders += 1
    }

    private static let english = "Gripper is closed. Open it before moving in."
    private static let chinese = "夾爪是合著的。先打開再靠近。"

    /// Nothing about the reminder was felt, heard or logged as a cue.
    private func assertNoCueOrSpeech(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(
            speech.spoken.contains { $0.contains("Gripper") || $0.contains("夾爪") }, "\(speech.spoken)", file: file,
            line: line)
        XCTAssertFalse(model.cueLog.contains { "\($0.event)".lowercased().contains("jaw") }, file: file, line: line)
    }

    /// A pad press and its release with the server's final answer. True when a start went on the wire.
    @discardableResult
    private func move(_ button: ButtonID = .left, jaws: String = "closed", degrees: Double = 0) -> Bool {
        let starts = wire.messages("pose_start").count
        model.buttonDown(button)
        noteShown()
        let sent = wire.messages("pose_start").count > starts
        clock += 50
        model.buttonUp(button)
        if let seq = wire.messages("pose_start").last?["seq"] as? Int {
            wire.receive("ack", ["seq": seq, "status": "ok", "reason": "pose_stopped"])
        }
        state(jaws: jaws, degrees: degrees)
        return sent
    }

    func testTheFirstMoveWithClosedJawsIsRemindedOnceAndStillGoesOut() {
        bringUp()
        XCTAssertTrue(move(), "the move is not held back")
        XCTAssertEqual(reminders, 1)
        XCTAssertTrue(move(.forward))
        XCTAssertTrue(move(.up))
        XCTAssertEqual(reminders, 1, "once an episode")
        assertNoCueOrSpeech()
    }

    /// The cues and the speech of a reminded move are exactly those of the same move with open jaws.
    func testTheReminderAddsNothingToTheCueStream() {
        var streams: [[CueKey]] = []
        var spoken: [[String]] = []
        for jaws in ["closed", "open"] {
            bringUp()
            if jaws == "open" { state(jaws: "open", degrees: 60) }
            let cuesBefore = model.cueLog.count
            let speechBefore = speech.spoken.count
            XCTAssertTrue(move(jaws: jaws, degrees: jaws == "open" ? 60 : 0))
            streams.append(model.cueLog.dropFirst(cuesBefore).map(\.event))
            spoken.append(Array(speech.spoken.dropFirst(speechBefore)))
            XCTAssertEqual(reminders, jaws == "closed" ? 1 : 0, jaws)
        }
        XCTAssertEqual(streams[0], streams[1])
        XCTAssertEqual(spoken[0], spoken[1])
    }

    func testItIsShownUnderMovingWhileTheRemindingMoveRuns() {
        bringUp()
        model.buttonDown(.left)
        XCTAssertEqual(model.operating.state, .moving(catchingUp: false))
        XCTAssertTrue(model.operating.openJawsFirst)
        XCTAssertEqual(OperatingWords.look(model.operating).details, [Self.english])
        L10n.language = .zhHant
        XCTAssertEqual(OperatingWords.look(model.operating).details, [Self.chinese])
        clock += OperatingRules.openJawsFirstShownMs
        state()
        XCTAssertFalse(model.operating.openJawsFirst, "shown for a while, not for the whole episode")
        model.buttonUp(.left)
        assertNoCueOrSpeech()
    }

    /// Once the jaws are open the line is no longer true: a move begun inside the showing time must not bring it back.
    func testTheLineGoesWhenTheJawsOpenAndDoesNotComeBackOnTheNextMove() {
        bringUp()
        move(jaws: "open", degrees: 60)
        XCTAssertEqual(reminders, 1)
        model.buttonDown(.left)
        XCTAssertLessThan(clock - (model.lastOpenJawsFirstAtMs ?? 0), OperatingRules.openJawsFirstShownMs)
        XCTAssertEqual(model.operating.state, .moving(catchingUp: false))
        XCTAssertFalse(model.operating.openJawsFirst, "the jaws are open now")
        XCTAssertEqual(OperatingWords.look(model.operating).details, [])
        model.buttonUp(.left)
    }

    /// The line sits under a translation's state only, in both languages: a stop, a stalled simulator or a refusal
    /// keeps its own lines.
    func testTheLineIsInBothLanguagesAndNeverCoversAStopAStallOrARefusal() throws {
        var facts = OperatingFacts()
        facts.connected = true
        facts.engaged = .translation
        facts.lastOpenJawsFirstAtMs = 1000
        facts.nowMs = 1100
        XCTAssertTrue(OperatingRules.showsOpenJawsFirst(facts))
        var stopped = facts
        stopped.emergencyStop = true
        XCTAssertFalse(OperatingRules.showsOpenJawsFirst(stopped))
        var stalled = facts
        stalled.simulatorStalled = true
        XCTAssertFalse(OperatingRules.showsOpenJawsFirst(stalled))
        var paused = facts
        paused.simulatorPaused = true
        XCTAssertFalse(OperatingRules.showsOpenJawsFirst(paused))
        var lost = facts
        lost.connected = false
        lost.connectionLost = true
        XCTAssertFalse(OperatingRules.showsOpenJawsFirst(lost))
        var refused = facts
        refused.engaged = nil
        refused.lastRefusal = (.posture, 1050)
        XCTAssertFalse(OperatingRules.showsOpenJawsFirst(refused))
        var later = facts
        later.nowMs = 1000 + OperatingRules.openJawsFirstShownMs
        XCTAssertFalse(OperatingRules.showsOpenJawsFirst(later))

        var display = try XCTUnwrap(OperatingFixtures.all["moving_hotel"])
        display.openJawsFirst = true
        XCTAssertEqual(OperatingWords.look(display).details, ["Catching up", Self.english])
        L10n.language = .zhHant
        XCTAssertEqual(OperatingWords.look(display).details, ["手臂跟上中", Self.chinese])
    }

    /// A phone move (the upper volume key held, the panel closed) is a translation like the pad's.
    func testAPhoneMoveIsRemindedToo() {
        bringUp()
        model.setPrecisionPanelOpen(false)
        let starts = wire.messages("pose_start").count
        model.keyEvent(.upper, down: true)
        noteShown()
        XCTAssertEqual(wire.messages("pose_start").count, starts + 1, "the move is not held back")
        XCTAssertEqual(reminders, 1)
        XCTAssertTrue(model.operating.openJawsFirst)
        model.keyEvent(.upper, down: false)
        assertNoCueOrSpeech()
    }

    func testOpenJawsShowNothing() {
        bringUp()
        state(jaws: "open", degrees: 60)
        XCTAssertTrue(move(jaws: "open", degrees: 60))
        XCTAssertEqual(reminders, 0)
    }

    func testAHeldCubeOrAGripShowsNothing() throws {
        bringUp()
        model.buttonDown(.close)
        clock += 100
        model.link.tick()
        state(degrees: 1.5, ik: "gripper_contact")
        model.buttonUp(.close)
        let seq = try XCTUnwrap(wire.messages("gripper_jog_start").last?["seq"] as? Int)
        wire.receive("ack", ["seq": seq, "status": "ok", "reason": "gripper_jog_stopped"])
        state(degrees: 55)
        XCTAssertTrue(model.link.holdingObject)
        XCTAssertTrue(move(degrees: 55))
        XCTAssertEqual(reminders, 0, "closed jaws are right while they hold the cube")
    }

    func testAMoveDuringAStopShowsNothing() {
        bringUp()
        state(estop: true)
        XCTAssertFalse(move(), "a stopped robot takes no move")
        XCTAssertEqual(reminders, 0)
    }

    func testANewEpisodeAndAResetArmItAgain() throws {
        bringUp()
        XCTAssertTrue(move())
        XCTAssertEqual(reminders, 1)
        state(episode: 2)
        // A scene reset closes the precision panel.
        model.setPrecisionPanelOpen(true)
        XCTAssertTrue(move(), "a new episode")
        XCTAssertEqual(reminders, 2, "a new episode")

        XCTAssertTrue(model.link.resetScene())
        let reset = try XCTUnwrap(wire.messages("reset_scene").last?["seq"] as? Int)
        wire.receive("ack", ["seq": reset, "status": "ok", "reason": "scene_reset"])
        state()
        model.setPrecisionPanelOpen(true)
        XCTAssertTrue(move(), "after a reset")
        XCTAssertEqual(reminders, 3, "the server's answer to a reset")
        assertNoCueOrSpeech()
    }

    func testAReconnectArmsItAgain() {
        bringUp()
        XCTAssertTrue(move())
        XCTAssertEqual(reminders, 1)
        model.link.closeQuietly()
        model.connect()
        welcome()
        XCTAssertTrue(move(), "after a reconnect")
        XCTAssertEqual(reminders, 2)
    }

    func testJawsOpenedThisEpisodeKeepItQuietAfterTheyCloseAgain() {
        bringUp()
        state(jaws: "open", degrees: 60)
        state(jaws: "close", degrees: 2)
        move(degrees: 2)
        XCTAssertEqual(reminders, 0)
    }
}
