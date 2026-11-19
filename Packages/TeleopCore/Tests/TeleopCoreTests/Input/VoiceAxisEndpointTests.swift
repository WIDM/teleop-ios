import XCTest
@testable import TeleopCore

final class VoiceAxisEndpointTests: XCTestCase {
    func testEarlyPhraseFinalizedAfterAdapterEndsAudioRemainsFresh() {
        for captured in [0.7, 1.2, 2.0] {
            var endpoint = VoiceAxisEndpoint(startedAt: 0)
            let deadlines = endpoint.deadlines(for: "只調高度", capturedAt: captured, now: captured + 0.1)
            var session = VoiceAxisSession()
            session.enable()
            let epoch = session.beginListening()!
            XCTAssertNil(
                session.accept(
                    "只調高度", final: false, epoch: epoch, capturedAt: captured,
                    now: captured + 0.1, inputIdle: true))
            let finalizedAt = deadlines.endAudioAt + 0.3
            XCTAssertLessThan(finalizedAt, deadlines.finishAt)
            XCTAssertEqual(
                session.accept(
                    "只調高度", final: true, epoch: epoch, capturedAt: captured,
                    now: finalizedAt, inputIdle: true), .height)
        }
    }

    func testDuplicatePartialDoesNotPostponeEndOfAudio() {
        var endpoint = VoiceAxisEndpoint(startedAt: 0)
        let first = endpoint.deadlines(for: "只調高度", capturedAt: 1, now: 1.1)
        XCTAssertEqual(endpoint.deadlines(for: "只調高度", capturedAt: 1, now: 2.5), first)
    }

    func testSlowPhraseCanUseFullCaptureWindowUntilExactPartialExists() {
        var endpoint = VoiceAxisEndpoint(startedAt: 10)
        XCTAssertEqual(endpoint.deadlines(for: "只調", capturedAt: 12, now: 12.1), endpoint.hardDeadlines)
        let deadlines = endpoint.deadlines(for: "只調前後", capturedAt: 14.3, now: 14.4)
        XCTAssertGreaterThan(deadlines.endAudioAt, 14.4)
        XCTAssertLessThan(deadlines.endAudioAt, 16)
    }

    func testChangedNonCommandPartialCancelsEarlyEndpoint() {
        var endpoint = VoiceAxisEndpoint(startedAt: 0)
        let proposed = endpoint.deadlines(for: "只調高度", capturedAt: 1, now: 1.1)
        XCTAssertLessThan(proposed.endAudioAt, 6)
        XCTAssertEqual(endpoint.deadlines(for: "只調高度不要移動", capturedAt: 1.3, now: 1.4), endpoint.hardDeadlines)
    }

    func testFinalResultAfterFreshnessWindowStillCannotSelect() {
        var endpoint = VoiceAxisEndpoint(startedAt: 0)
        let deadlines = endpoint.deadlines(for: "只調左右", capturedAt: 1, now: 1.1)
        XCTAssertLessThanOrEqual(deadlines.finishAt, 4)
        var session = VoiceAxisSession()
        session.enable()
        let epoch = session.beginListening()!
        XCTAssertNil(session.accept("只調左右", final: true, epoch: epoch, capturedAt: 1, now: 4.01, inputIdle: true))
        session.suspend()
        XCTAssertNil(session.accept("只調左右", final: true, epoch: epoch, capturedAt: 1, now: 1.5, inputIdle: true))
    }
}
