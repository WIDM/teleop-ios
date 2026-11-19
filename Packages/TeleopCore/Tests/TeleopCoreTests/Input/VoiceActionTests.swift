import XCTest
@testable import TeleopCore

final class VoiceActionTests: XCTestCase {
    func testWholeAffirmativeCommandsMapToOneAction() {
        for (words, action) in [
            ("往前一點", VoiceAction.forward), ("向前一点。", .forward),
            ("往 上 一 點", .up), ("Move up a little!", .up),
            ("開爪", .open), ("打 开 夹 爪", .open), ("Open the gripper.", .open),
            ("關爪", .close), ("关闭夹爪。", .close), ("close gripper", .close),
        ] {
            XCTAssertEqual(VoiceAction.recognized(words), action, words)
        }
        for words in [
            "", "開", "不要開爪", "先開爪再關爪", "開爪、關爪", "往前",
            "往前一點，然後往上一點", "只調高度", "don't open gripper", "close gripper twice",
        ] {
            XCTAssertNil(VoiceAction.recognized(words), words)
        }
    }

    func testDuplicateAndStaleTranscriptsCannotTriggerActions() throws {
        var session = VoiceAxisSession()
        session.enable()
        let first = try XCTUnwrap(session.beginListening())
        XCTAssertEqual(
            session.accept("只調高度", final: true, epoch: first, capturedAt: 10, now: 11, inputIdle: true),
            .height)
        let second = try XCTUnwrap(session.beginListening())
        XCTAssertNil(session.acceptAction("開爪", final: false, epoch: second, capturedAt: 12, now: 13, inputIdle: true))
        XCTAssertNil(session.acceptAction("開爪", final: true, epoch: first, capturedAt: 12, now: 13, inputIdle: true))
        XCTAssertNil(session.acceptAction("開爪", final: true, epoch: second, capturedAt: 12, now: 16, inputIdle: true))
        XCTAssertNil(session.acceptAction("開爪", final: true, epoch: second, capturedAt: 12, now: 11, inputIdle: true))
        XCTAssertNil(session.acceptAction("開爪", final: true, epoch: second, capturedAt: 12, now: 13, inputIdle: false))
        XCTAssertEqual(
            session.acceptAction("開爪", final: true, epoch: second, capturedAt: 12, now: 13, inputIdle: true), .open)
        XCTAssertEqual(session.axis, .height)
        XCTAssertNil(session.acceptAction("開爪", final: true, epoch: second, capturedAt: 12, now: 13, inputIdle: true))

        let third = try XCTUnwrap(session.beginListening())
        XCTAssertNil(session.acceptAction("開爪", final: true, epoch: second, capturedAt: 13, now: 14, inputIdle: true))
        XCTAssertEqual(
            session.acceptAction("開爪", final: true, epoch: third, capturedAt: 13, now: 14, inputIdle: true), .open)
    }

    func testRecognizedActionUsesTheExistingShortCaptureWindow() {
        var endpoint = VoiceAxisEndpoint(startedAt: 0)
        XCTAssertEqual(endpoint.deadlines(for: "往前", capturedAt: 1, now: 1.1), endpoint.hardDeadlines)
        let deadlines = endpoint.deadlines(for: "往前一點", capturedAt: 1.2, now: 1.3)
        XCTAssertEqual(deadlines.endAudioAt, 1.8, accuracy: 1e-6)
        XCTAssertEqual(deadlines.finishAt, 4.2, accuracy: 1e-6)
        XCTAssertEqual(endpoint.deadlines(for: "往前一點不要", capturedAt: 1.4, now: 1.5), endpoint.hardDeadlines)
    }
}
