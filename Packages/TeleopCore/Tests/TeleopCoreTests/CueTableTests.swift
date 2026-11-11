import Foundation
import XCTest
@testable import TeleopCore

/// The event to cue table (interaction specification §5.3, C-F1, C-F2) and the spoken strings it names.
final class CueTableTests: XCTestCase {
    func testEveryEventHasExactlyOneRow() {
        for key in CueKey.allCases {
            XCTAssertEqual(CueTable.rows.filter { $0.key == key }.count, 1, "\(key)")
        }
        XCTAssertEqual(CueTable.rows.count, CueKey.allCases.count, "a row for something that is not an event")
        XCTAssertEqual(Set(CueKey.allCases).count, CueKey.allCases.count)
    }

    func testEveryEventIsFeltOrHeard() {
        for row in CueTable.rows {
            XCTAssertTrue(row.haptic != nil || row.sound != nil || !row.speech.isEmpty, "\(row.key) plays nothing")
            XCTAssertEqual(row.level == nil, row.speech.isEmpty, "\(row.key): a level exactly when something is spoken")
        }
    }

    /// The events the owner named as core each have a haptic and sound pair no other event has; the few that
    /// share one share its meaning (C-F1).
    func testTheCoreEventsAreToldApart() {
        let core: [CueKey] = [
            .holdLive, .refused(.noLink), .letGo(.tooFast), .limit(.workspace), .contact,
            .linkLost(holdEngaged: false), .emergencyStop(.button, takeDiscarded: false), .takeSaved, .takeDiscarded,
        ]
        let pairs = core.map { key -> String in
            let row = CueTable.row(for: key)
            return "\(row.haptic?.rawValue ?? "-")/\(row.sound?.rawValue ?? "-")"
        }
        XCTAssertEqual(Set(pairs).count, core.count, "\(pairs)")
        let sharing: [CueKey: CueKey] = [.taskSuccess: .takeSaved, .successNotSaved: .takeDiscarded,
                                         .offlineSaved: .takeSaved, .offlineDiscarded: .takeDiscarded]
        for (key, same) in sharing {
            XCTAssertEqual(CueTable.row(for: key).sound, CueTable.row(for: same).sound, "\(key)")
        }
    }

    /// ALARM means emergency stop and nothing else.
    func testOnlyTheEmergencyStopRattles() {
        for row in CueTable.rows {
            if case .emergencyStop = row.key {
                XCTAssertEqual(row.haptic, .alarm)
                XCTAssertEqual(row.level, .p1)
            } else {
                XCTAssertNotEqual(row.haptic, .alarm, "\(row.key)")
            }
        }
    }

    func testAnEmergencyStopSaysTheTakeWasDiscardedOnlyWhenItWas() {
        XCTAssertEqual(CueTable.phrases(for: .emergencyStop(.link, takeDiscarded: true)).map(\.key),
                       [.estop, .causeLink, .takeDiscarded, .resetPrompt])
        XCTAssertEqual(CueTable.phrases(for: .emergencyStop(.button, takeDiscarded: false)).map(\.key),
                       [.estop, .causeButton, .resetPrompt])
    }

    func testNumbersGoToThePhrasesThatTakeThem() {
        XCTAssertEqual(CueTable.phrases(for: .recordingSession(saved: 12)),
                       [Phrase(.recordingSession), Phrase(.savedCount, number: 12)])
        XCTAssertEqual(CueTable.phrases(for: .takeSaved(count: 13)), [Phrase(.savedN, number: 13)])
    }

    func testEveryKeyTheTableSpeaksIsAKnownKey() {
        let spoken = Set(CueTable.rows.flatMap(\.speech))
        XCTAssertEqual(spoken, Set(SpeechKey.allCases), "a speech key no event speaks, or the other way round")
    }

    /// Every phrase exists in English and Traditional Chinese, with the same number of `%d`, in the app's
    /// `Speech` table. Chinese uses full-width punctuation and never the English words for the bands.
    func testEverySpokenKeyExistsInBothLanguages() throws {
        let catalog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Resources/Speech.xcstrings")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: [String: Any]])
        XCTAssertEqual(Set(strings.keys), Set(SpeechKey.allCases.map(\.rawValue)), "the table and the catalog differ")
        for key in SpeechKey.allCases {
            let localizations = strings[key.rawValue]?["localizations"] as? [String: [String: [String: String]]]
            let english = try XCTUnwrap(localizations?["en"]?["stringUnit"]?["value"], key.rawValue)
            let chinese = try XCTUnwrap(localizations?["zh-Hant"]?["stringUnit"]?["value"], key.rawValue)
            XCTAssertFalse(english.isEmpty || chinese.isEmpty, key.rawValue)
            let specifiers = { (text: String) in text.components(separatedBy: "%d").count - 1 }
            XCTAssertEqual(specifiers(english), key.takesNumber ? 1 : 0, key.rawValue)
            XCTAssertEqual(specifiers(chinese), specifiers(english), key.rawValue)
            XCTAssertFalse(chinese.contains("STOP") || chinese.contains("Reset"), key.rawValue)
            XCTAssertFalse(chinese.contains { ",.:;!?".contains($0) }, "\(key.rawValue): half-width punctuation in \(chinese)")
            XCTAssertLessThanOrEqual(english.split(separator: " ").count, 9, key.rawValue)
        }
    }

    /// C-F2: no two event patterns share their count of pulses and their sequence of long and short.
    func testTheSixPatternsDifferInRhythm() {
        let rhythms = Haptic.allCases.map(\.rhythm)
        XCTAssertEqual(Set(rhythms.map { $0.map { $0 ? "L" : "s" }.joined() }).count, Haptic.allCases.count)
        XCTAssertEqual(Haptic.go.rhythm, [false])
        XCTAssertEqual(Haptic.no.rhythm, [false, false, false])
        XCTAssertEqual(Haptic.grip.rhythm, [false, false])
        XCTAssertEqual(Haptic.end.rhythm, [true])
        XCTAssertEqual(Haptic.letGo.rhythm, [true, true])
        XCTAssertEqual(Haptic.alarm.rhythm.count, 15)
        XCTAssertEqual(Haptic.alarm.durationMs, 1450)
    }

    func testPriorityOrder() {
        let order: [Haptic] = [.alarm, .letGo, .no, .grip, .end, .go]
        XCTAssertEqual(Haptic.allCases.sorted { $0.priority > $1.priority }, order)
    }
}
