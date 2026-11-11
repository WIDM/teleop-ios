import TeleopCore
import XCTest
@testable import Teleop

/// The spoken phrases come out of the built app's `Speech` table in both languages.
final class SpeechTextTests: XCTestCase {
    func testEveryPhraseResolvesInBothLanguages() {
        for key in SpeechKey.allCases {
            let phrase = [Phrase(key, number: key.takesNumber ? 13 : nil)]
            let english = SpeechText.string(phrase, language: .en)
            let chinese = SpeechText.string(phrase, language: .zhHant)
            XCTAssertNotEqual(english, key.rawValue, "\(key.rawValue) has no English text in the app")
            XCTAssertNotEqual(chinese, key.rawValue, "\(key.rawValue) has no Chinese text in the app")
            XCTAssertNotEqual(english, chinese, key.rawValue)
            XCTAssertFalse(english.contains("%"), key.rawValue)
            if key.takesNumber {
                XCTAssertTrue(english.contains("13") && chinese.contains("13"), key.rawValue)
            }
        }
    }

    func testAnEventIsSpokenAsOneSentence() {
        XCTAssertEqual(SpeechText.string(CueTable.phrases(for: .recordingSession(saved: 12)), language: .en), "Recording session. 12 saved.")
        XCTAssertEqual(SpeechText.string(CueTable.phrases(for: .recordingSession(saved: 12)), language: .zhHant), "錄製模式。已存 12 筆。")
        XCTAssertEqual(SpeechText.string(CueTable.phrases(for: .takeSaved(count: 13)), language: .en), "Saved. 13.")
    }

    func testTheVoiceFollowsTheAppsLanguage() {
        XCTAssertEqual(SpeechText.voiceLanguage(.en), "en-US")
        XCTAssertEqual(SpeechText.voiceLanguage(.zhHant), "zh-TW")
    }
}
