import XCTest
@testable import TeleopCore

/// The rows for a touch on the guide that was not taken as a tap, for a move ended by a second touch on the tapped
/// spot, and for a hold a slow link let go of. A tap's reason is queued behind the words that play, so at the pace of
/// a person tapping it is still said after "Stopped here.", once.
final class TapRowsTests: XCTestCase {
    private static let newKeys: [CueKey] = [
        .refused(.tapStill), .refused(.tapLetGo), .refused(.tapViewAbove), .letGo(.slowLink),
        .drive(.stoppedByYouTapOnce),
    ]

    func testEveryNewKeyHasOneRow() {
        for key in Self.newKeys {
            XCTAssertTrue(CueKey.allCases.contains(key), "\(key) is an event")
            XCTAssertEqual(CueTable.rows.filter { $0.key == key }.count, 1, "\(key)")
        }
    }

    func testATouchThatWasNotATapIsANoWithItsReasonQueued() {
        let reasons: [Refusal: SpeechKey] = [.tapStill: .tapStill, .tapLetGo: .tapLetGo, .tapViewAbove: .tapViewAbove]
        for (refusal, phrase) in reasons {
            let row = CueTable.row(for: .refused(refusal))
            XCTAssertEqual(row.haptic, .no, "\(refusal)")
            XCTAssertNil(row.sound, "\(refusal)")
            XCTAssertEqual(row.speech, [phrase], "\(refusal)")
            XCTAssertEqual(row.level, .p2, "\(refusal): waits for the voice, never dropped")
        }
    }

    func testASlowLinkThatLetsGoSaysSlowLinkAsEveryLetGoIsSaid() {
        let row = CueTable.row(for: .letGo(.slowLink))
        XCTAssertEqual(row.haptic, .letGo)
        XCTAssertNil(row.sound)
        XCTAssertEqual(row.speech, [.slowLink])
        XCTAssertEqual(row.level, .p4)
        XCTAssertEqual(CueTable.row(for: .letGo(.tooFast)).level, row.level, "the level of every let-go")
        XCTAssertEqual(DriveEnd(byLink: .slowLink), .slowLink)
    }

    func testTheTapOnceEndingSaysStoppedHereThenTapOnce() {
        let row = CueTable.row(for: .drive(.stoppedByYouTapOnce))
        XCTAssertEqual(row.haptic, CueTable.row(for: .drive(.stoppedByYou)).haptic, "felt as any ending by a touch")
        XCTAssertEqual(row.speech, [.driveStoppedHere, .tapOnce])
        XCTAssertEqual(row.level, .p2)
        XCTAssertTrue(DriveCue.allCases.contains(.stoppedByYouTapOnce))
    }

    /// "Stopped here." starts at 0 ms; a near tap refused 280 ms later, as fast as a person taps again, is felt at
    /// once and its reason waits; it is said when the voice is free, once, and a second one within 3 s is not said.
    func testATapPhraseRaisedWhileStoppedHereIsSpokenAfterIt() throws {
        var scheduler = CueScheduler()
        let ended = scheduler.raise(.drive(.stoppedByYou), at: 0, currentHold: nil)
        let stoppedHere = try XCTUnwrap(utterance(ended))
        XCTAssertEqual(stoppedHere.phrases, [Phrase(.driveStoppedHere)])

        let refused = scheduler.raise(.refused(.tapStill), at: 280, currentHold: nil)
        XCTAssertTrue(refused.contains(.haptic(.no)), "the NO is felt at once: \(refused)")
        XCTAssertNil(utterance(refused), "the reason waits for the voice")
        XCTAssertEqual(scheduler.log.last?.speech, [.tapStill], "decided, and not dropped")
        XCTAssertEqual(scheduler.log.last?.dropped, false)

        let again = scheduler.raise(.refused(.tapStill), at: 600, currentHold: nil)
        XCTAssertNil(utterance(again))
        XCTAssertEqual(scheduler.log.last?.speech, [], "a second one within 3 s is not said")

        let freed = scheduler.speechFinished(id: stoppedHere.id, at: 900)
        let reason = try XCTUnwrap(utterance(freed), "said once the voice is free")
        XCTAssertEqual(reason.phrases, [Phrase(.tapStill)])

        XCTAssertEqual(scheduler.speechFinished(id: reason.id, at: 1800), [], "said once")
        XCTAssertNil(utterance(scheduler.raise(.refused(.tapStill), at: 2500, currentHold: nil)))
        XCTAssertEqual(scheduler.tick(at: 4000, currentHold: nil), [], "nothing left waiting")
    }

    private func utterance(_ outputs: [CueOutput]) -> (phrases: [Phrase], id: Int)? {
        for output in outputs {
            if case .speak(let phrases, _, let id) = output { return (phrases, id) }
        }
        return nil
    }
}
