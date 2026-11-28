import simd
import TeleopCore
import XCTest
@testable import Teleop

private final class RefusalWordsTransport: LinkTransport {
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

/// A server's refusal or ending of a manual arm hold is said and shown by what the operator can do about it, on every
/// path a refusal reaches the operator: a refused start, a hold the server ends later, a refusal during a restart that
/// keeps one hold going, the pad's buttons, and a move nobody holds. The hold still ends and nothing restarts.
final class ServerRefusalWordsTests: XCTestCase {
    private var model: AppModel!
    private var wire: RefusalWordsTransport!
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

    private func bringUp(aids: Bool = false, lock: LockChoice = .off) {
        clock = 10_000
        UserDefaults.standard.set(false, forKey: AppModel.taskAidKey)
        wire = RefusalWordsTransport()
        wire.now = { [unowned self] in clock }
        model = AppModel(
            start: .p4, haptics: NoHaptics(), sounds: SpySounds(), speech: SpySpeech(),
            pose: { TestPose.portrait }, liveLink: true,
            makeTransport: { [unowned self] _ in wire }, makeObserverTransport: { _ in RefusalWordsTransport() },
            nowMs: { [unowned self] in clock }, inputClock: { [unowned self] in Double(clock) / 1000 },
            assistOn: aids, lockChoice: lock)
        model.controlMode = .screenTurns
        model.session.state.setSmoothing(0)
        model.session.state.sensitivity = 1
        model.session.state.serverAddress = "127.0.0.1:8765"
        model.connect()
        wire.receive("welcome", ["control_points": ["link_origin", "tool"], "tool_calibration_id": "test-tool"])
        state()
        model.surfaceChanged(width: 375, height: 667, safeTop: 20, safeBottom: 0)
    }

    private func state() {
        wire.receive(
            "state",
            [
                "estop": false, "ik": "ok", "gripper": "open", "ee_pos": [0, -0.14, 0.16],
                "tool_pos": [0.01, -0.17, 0.07],
            ])
    }

    private func newestStart() throws -> Int {
        try XCTUnwrap(wire.messages("pose_start").last?["seq"] as? Int)
    }

    private func refuse(_ sequence: Int, _ reason: String) {
        wire.receive("ack", ["seq": sequence, "status": "rejected", "reason": reason])
    }

    /// Ticks with the arm reported, past the acceptance time, so the hold has had its GO.
    private func accept() {
        for _ in 0..<5 {
            clock += 100
            state()
            model.link.tick()
        }
        XCTAssertTrue(model.cueLog.contains { $0.event == .holdLive }, "accepted")
    }

    private func entries(_ key: CueKey) -> [CueLogEntry] { model.cueLog.filter { $0.event == key } }

    private var generalWords: [CueLogEntry] {
        model.cueLog.filter {
            $0.event == .letGo(.lateRejection) || $0.event == .refused(.serverRefused)
                || $0.event == .drive(.ended(.serverRefused))
        }
    }

    /// The hold ended and nothing restarts it: no new start and no updates.
    private func assertEndedForGood(_ what: String) {
        XCTAssertFalse(model.session.state.armMoving, what)
        let starts = wire.messages("pose_start").count
        let updates = wire.messages("pose_update").count
        for _ in 0..<5 {
            clock += 100
            state()
            model.link.tick()
        }
        XCTAssertEqual(wire.messages("pose_start").count, starts, "\(what): nothing restarts")
        XCTAssertEqual(wire.messages("pose_update").count, updates, "\(what): nothing streams")
    }

    private var look: OperatingWords.Look { OperatingWords.look(model.operating) }

    // MARK: A hold someone holds

    func testARefusedStartSaysAndShowsWhatToDo() throws {
        let cases: [(String, ServerRefusalClass, SpeechKey, String)] = [
            ("tool_measured_corridor", .contact, .refusedContact, "Touching something"),
            ("tool_joint_limit", .jointLimit, .refusedJointLimit, "Arm at its limit"),
            ("tool_no_converged_path", .reach, .refusedReach, "Can't reach that way"),
        ]
        for (reason, refusalClass, key, word) in cases {
            bringUp()
            model.keyEvent(.upper, down: true)
            refuse(try newestStart(), reason)
            let heard = entries(.serverRefusal(refusalClass, accepted: false))
            XCTAssertEqual(heard.count, 1, reason)
            XCTAssertEqual(heard.first?.haptic, .no, reason)
            XCTAssertEqual(heard.first?.speech, [key], reason)
            XCTAssertTrue(generalWords.isEmpty, reason)
            XCTAssertEqual(model.operating.state, .serverRefused(refusalClass, moveEnded: false), reason)
            XCTAssertEqual(look.word, word, reason)
            XCTAssertEqual(look.colour, TeleopColors.stateAmber, reason)
            assertEndedForGood(reason)
            model.keyEvent(.upper, down: false)
        }
    }

    func testAHoldTheServerEndsLaterSaysWhatToDo() throws {
        bringUp()
        model.keyEvent(.upper, down: true)
        let start = try newestStart()
        accept()
        refuse(start, "tool_wrist_unsettled")
        let heard = entries(.serverRefusal(.contact, accepted: true))
        XCTAssertEqual(heard.count, 1)
        XCTAssertEqual(heard.first?.haptic, .letGo)
        XCTAssertEqual(heard.first?.speech, [.refusedContact])
        XCTAssertTrue(generalWords.isEmpty)
        assertEndedForGood("ended later")
        model.keyEvent(.upper, down: false)
    }

    func testAnUnknownReasonKeepsTodaysWords() throws {
        bringUp()
        model.keyEvent(.upper, down: true)
        refuse(try newestStart(), "tool_target_lead")
        XCTAssertEqual(entries(.refused(.serverRefused)).count, 1)
        XCTAssertEqual(model.operating.state, .refused(.serverRefused))
        XCTAssertEqual(look.word, "The server refused that move")
        model.keyEvent(.upper, down: false)

        bringUp()
        model.keyEvent(.upper, down: true)
        let start = try newestStart()
        accept()
        refuse(start, "some_new_reason")
        XCTAssertEqual(entries(.letGo(.lateRejection)).count, 1)
        XCTAssertEqual(entries(.letGo(.lateRejection)).first?.speech, [.refusedMove])
        model.keyEvent(.upper, down: false)
    }

    func testThePadsButtonsSayWhatToDo() throws {
        bringUp()
        model.setPrecisionPanelOpen(true)
        model.buttonDown(.down)
        clock += 350
        model.link.tick()
        refuse(try newestStart(), "tool_origin_workspace")
        let heard = model.cueLog.filter {
            $0.event == .serverRefusal(.reach, accepted: false) || $0.event == .serverRefusal(.reach, accepted: true)
        }
        XCTAssertEqual(heard.count, 1)
        XCTAssertEqual(heard.first?.speech, [.refusedReach])
        XCTAssertTrue(generalWords.isEmpty)
        assertEndedForGood("pad")
        model.buttonUp(.down)
    }

    /// The build 28 path: the start that keeps one hold going across a restart is refused while the restart waits.
    func testARefusalDuringARestartSaysWhatToDoOnce() throws {
        for stopFirst in [false, true] {
            bringUp()
            XCTAssertTrue(model.link.startButtonHold(useToolPoint: true, { SIMD3(0.02, 0, 0) }))
            let start = try newestStart()
            clock += 510
            state()
            model.link.tick()
            let stop = try XCTUnwrap(wire.messages("pose_stop").last?["seq"] as? Int)
            let rejectedStart: [String: Any] = [
                "seq": start, "status": "rejected", "reason": "tool_actuator_joint_limit",
            ]
            let rejectedStop: [String: Any] = ["seq": stop, "status": "rejected", "reason": "pose_not_active"]
            wire.receive("ack", stopFirst ? rejectedStop : rejectedStart)
            wire.receive("ack", stopFirst ? rejectedStart : rejectedStop)
            let heard = model.cueLog.filter {
                if case .serverRefusal(.jointLimit, _) = $0.event { return true } else { return false }
            }
            XCTAssertEqual(heard.count, 1, "stopFirst = \(stopFirst)")
            XCTAssertEqual(heard.first?.speech, [.refusedJointLimit], "stopFirst = \(stopFirst)")
            XCTAssertTrue(generalWords.isEmpty, "stopFirst = \(stopFirst)")
            clock += TestProfiles.so101.server.resync.timeoutMs + 1
            state()
            model.link.tick()
            XCTAssertFalse(model.cueLog.contains { $0.event == .letGo(.noAnswer) }, "stopFirst = \(stopFirst)")
            XCTAssertEqual(wire.messages("pose_start").count, 1, "stopFirst = \(stopFirst)")
        }
    }

    // MARK: A move nobody holds

    func testAMoveNobodyHoldsSaysStoppedHereThenWhatToDo() throws {
        let cases: [(String, ServerRefusalClass, SpeechKey, String)] = [
            ("tool_joint_step", .contact, .refusedContact, "Touching something. Open the gripper or lift"),
            ("tool_joint_limit", .jointLimit, .refusedJointLimit, "Arm at its limit. Move the other way"),
            ("tool_path_corridor", .reach, .refusedReach, "Can't reach that way. Back off a little"),
        ]
        for (reason, refusalClass, key, detail) in cases {
            for accepted in [false, true] {
                let what = "\(reason), accepted \(accepted)"
                bringUp(aids: true, lock: .pressPress)
                clock += 100
                model.keyEvent(.upper, down: true)
                clock += 100
                model.keyEvent(.upper, down: false)
                XCTAssertTrue(model.link.holdIsLoose, what)
                let start = try newestStart()
                if accepted { accept() }
                let before = model.cueLog.count
                refuse(start, reason)
                let after = model.cueLog.dropFirst(before)
                XCTAssertEqual(after.map(\.event), [.drive(.endedByServer(refusalClass))], what)
                XCTAssertEqual(after.first?.speech, [.driveStoppedHere, key], what)
                XCTAssertNil(model.controller.arbiter.engagement, what)
                XCTAssertFalse(model.link.holdIsLoose, what)
                XCTAssertEqual(model.operating.state, .serverRefused(refusalClass, moveEnded: true), what)
                XCTAssertEqual(look.word, "Stopped here", what)
                XCTAssertEqual(look.details, [detail], what)
                assertEndedForGood(what)
                XCTAssertEqual(model.cueLog.dropFirst(before).count, 1, "\(what): told once")
            }
        }
    }

    // MARK: Both languages

    func testTheScreenWordsInBothLanguages() {
        let words: [AppLanguage: [ServerRefusalClass: String]] = [
            .en: [
                .contact: "Touching something", .jointLimit: "Arm at its limit", .reach: "Can't reach that way",
                .other: "The server refused that move",
            ],
            .zhHant: [
                .contact: "碰到東西", .jointLimit: "手臂彎到底", .reach: "這個方向到不了", .other: "伺服器拒絕了這個動作",
            ],
        ]
        for (language, table) in words {
            L10n.language = language
            for (refusalClass, word) in table {
                XCTAssertEqual(OperatingWords.reason(refusalClass), word, "\(language) \(refusalClass)")
            }
            XCTAssertEqual(OperatingWords.reason(.other), OperatingWords.reason(Refusal.serverRefused))
        }
        L10n.language = .zhHant
        XCTAssertEqual(
            SpeechText.string(CueTable.phrases(for: .drive(.endedByServer(.contact)))), "停在這裡。碰到東西了。打開夾爪或抬高再試。")
        XCTAssertEqual(
            SpeechText.string(CueTable.phrases(for: .serverRefusal(.jointLimit, accepted: true))), "手臂彎到底了。請往反方向移。")
        XCTAssertEqual(
            SpeechText.string(CueTable.phrases(for: .serverRefusal(.reach, accepted: false))), "這個方向到不了。請退回一點。")
        L10n.language = .en
        XCTAssertEqual(
            SpeechText.string(CueTable.phrases(for: .drive(.endedByServer(.reach)))),
            "Stopped here. Can't reach that way. Back off a little.")
    }
}
