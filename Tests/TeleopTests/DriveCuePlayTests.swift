import TeleopCore
import XCTest
@testable import Teleop

/// The cues of a move nobody holds reach the operator through the app: the latch's own pattern reaches the haptic
/// player, which plays any `Haptic` from its pattern; the endings are spoken "Stopped here." then why, in both
/// languages; and the two refusals of a tap have their words on the screen.
final class DriveCuePlayTests: XCTestCase {
    private var savedLanguage = L10n.language

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.language
        L10n.language = .en
    }

    override func tearDown() {
        L10n.language = savedLanguage
        super.tearDown()
    }

    func testTheLatchPatternReachesTheHapticPlayer() {
        let felt = SpyHaptics(), speech = SpySpeech()
        let model = AppModel(start: .p4, haptics: felt, sounds: SpySounds(), speech: speech, liveLink: false)
        model.raise(.drive(.latched))
        XCTAssertEqual(felt.felt, [.play(.latch)])
        XCTAssertEqual(speech.spoken, ["Locked on."])
        XCTAssertEqual(model.cueLog.last?.haptic, .latch)
    }

    func testAnEndingIsStoppedHereThenItsReason() {
        var clock = 0
        let felt = SpyHaptics(), speech = SpySpeech()
        let model = AppModel(
            start: .p4, haptics: felt, sounds: SpySounds(), speech: speech, liveLink: false, nowMs: { clock })
        model.raise(.drive(.ended(.timeLimit)))
        clock += 2000
        model.raise(.drive(.stoppedByYou))
        clock += 2000
        model.raise(.drive(.ended(.unnamed)))
        XCTAssertEqual(felt.felt, [.play(.letGo), .play(.end), .play(.letGo)])
        XCTAssertEqual(speech.spoken, ["Stopped here. Time is up.", "Stopped here.", "Stopped here."])
        let timeUp = CueTable.phrases(for: .drive(.ended(.timeLimit)))
        XCTAssertEqual(SpeechText.string(timeUp, language: .zhHant), "停在這裡。時間到了。")
        XCTAssertEqual(SpeechText.string(CueTable.phrases(for: .refused(.emergencyStop)), language: .en), "Stopped.")
    }

    /// The endings an operator hears mid-task read as one plain sentence each, in both languages.
    func testTheEndingsSayWhyInPlainWords() {
        let said: [(DriveEnd, String, String)] = [
            (.appLeft, "Stopped here. You left the app.", "停在這裡。你離開了程式。"),
            (.stoppedShort, "Stopped here. Short of the target.", "停在這裡。沒走到目標。"),
            (.serverBusy, "Stopped here. The server was busy.", "停在這裡。伺服器正忙。"),
        ]
        for (end, english, chinese) in said {
            let phrases = CueTable.phrases(for: .drive(.ended(end)))
            XCTAssertEqual(SpeechText.string(phrases, language: .en), english, "\(end)")
            XCTAssertEqual(SpeechText.string(phrases, language: .zhHant), chinese, "\(end)")
        }
    }

    func testTheHeightFloorRefusalIsFeltSpokenAndWrittenInBothLanguages() {
        for language in [AppLanguage.en, .zhHant] {
            L10n.language = language
            let felt = SpyHaptics(), speech = SpySpeech()
            let model = AppModel(start: .p4, haptics: felt, sounds: SpySounds(), speech: speech, liveLink: false)
            model.raise(.refused(OperatingController.refusal(.useUpperKey)))
            XCTAssertEqual(felt.felt, [.play(.no)])
            XCTAssertEqual(
                speech.spoken,
                [
                    language == .en
                        ? "To lower further, hold the upper volume key."
                        : "更低請按住上音量鍵，往下移動手機。"
                ])
            XCTAssertEqual(
                OperatingWords.reason(.useUpperKey),
                language == .en
                    ? "Hold + to lower" : "按住上鍵下降")
        }
    }

    func testTheTapsRefusalsHaveTheirWords() {
        XCTAssertEqual(OperatingController.refusal(.outsideWorkArea), .outsideWorkArea)
        XCTAssertEqual(OperatingController.refusal(.noArmData), .noArmData)
        XCTAssertEqual(OperatingWords.reason(.outsideWorkArea), "Outside the work area")
        XCTAssertEqual(OperatingWords.reason(.noArmData), "No arm data")
        L10n.language = .zhHant
        XCTAssertEqual(OperatingWords.reason(.outsideWorkArea), "超出工作範圍")
        XCTAssertEqual(OperatingWords.reason(.noArmData), "收不到手臂資料")
    }
}
