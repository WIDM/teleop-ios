import Foundation
import XCTest
@testable import TeleopCore

/// The cues of a move nobody holds: it latched, it arrived, or it ended and why. None may be dropped or silent, the
/// latch must not pass for GO, and an ended move must not sound like a refused press.
final class DriveCueTests: XCTestCase {
    private var driveRows: [CueRow] {
        CueTable.rows.filter {
            if case .drive = $0.key { return true }
            return false
        }
    }

    func testEveryDriveRowSpeaksAtP2AndHasAHaptic() {
        XCTAssertEqual(driveRows.count, 3 + DriveEnd.allCases.count)
        XCTAssertEqual(Set(driveRows.map(\.key)), Set(DriveCue.allCases.map(CueKey.drive)))
        for row in driveRows {
            XCTAssertNotNil(row.haptic, "\(row.key)")
            XCTAssertFalse(row.speech.isEmpty, "\(row.key)")
            XCTAssertEqual(row.level, .p2, "\(row.key): queued, never dropped")
        }
    }

    func testTheLatchIsItsOwnPattern() {
        XCTAssertEqual(CueTable.rows.filter { $0.haptic == .latch }.map(\.key), [.drive(.latched)])
        XCTAssertEqual(CueTable.row(for: .drive(.latched)).speech, [.driveLocked])
        XCTAssertEqual(Haptic.latch.rhythm, [true, false], "a long buzz, then a tick")
        XCTAssertEqual(Haptic.latch.pattern.pulses.map(\.startMs), [0, 360])
        XCTAssertEqual(Haptic.latch.pattern.pulses.map(\.durationMs), [260, 0])
        XCTAssertFalse(Haptic.latch.pattern.repeats)
        for other in Haptic.allCases where other != .latch {
            XCTAssertNotEqual(other.rhythm, Haptic.latch.rhythm, "\(other)")
        }
        XCTAssertGreaterThan(Haptic.no.priority, Haptic.latch.priority)
        XCTAssertGreaterThan(Haptic.latch.priority, Haptic.grip.priority)
    }

    func testEveryEndingSaysStoppedHereFirst() {
        XCTAssertEqual(CueTable.row(for: .drive(.stoppedByYou)).speech, [.driveStoppedHere])
        XCTAssertEqual(CueTable.row(for: .drive(.stoppedByYou)).haptic, .end)
        XCTAssertEqual(CueTable.row(for: .drive(.ended(.unnamed))).speech, [.driveStoppedHere])
        XCTAssertEqual(CueTable.row(for: .drive(.arrived)).speech, [.driveArrived])
        XCTAssertEqual(CueTable.row(for: .drive(.arrived)).haptic, .end)
        let reasons: [DriveEnd: SpeechKey] = [
            .posture: .posture, .tracking: .lostTracking, .timeLimit: .driveTimeUp, .appLeft: .driveAppLeft,
            .cameraStopped: .driveCamera, .leftScreen: .driveLeftScreen, .slowLink: .slowLink,
            .stoppedShort: .driveShort, .noArmData: .noArmData, .tooFast: .tooFast, .noAnswer: .noAnswer,
            .linkHiccup: .linkHiccup, .serverRefused: .refusedMove, .serverBusy: .wait,
        ]
        XCTAssertEqual(Set(reasons.keys).union([.unnamed]), Set(DriveEnd.allCases))
        for end in DriveEnd.allCases {
            let row = CueTable.row(for: .drive(.ended(end)))
            XCTAssertEqual(row.haptic, .letGo, "\(end)")
            XCTAssertEqual(row.speech.first, .driveStoppedHere, "\(end)")
            XCTAssertEqual(row.speech, [.driveStoppedHere] + (reasons[end].map { [$0] } ?? []), "\(end)")
        }
    }

    /// "Stopped." refuses a press while the robot is in emergency stop; "Stopped here." tells a move that ended.
    /// The two never share a key or a word.
    func testStoppedHereIsNotTheRefusalsStopped() throws {
        for row in driveRows {
            XCTAssertFalse(row.speech.contains(.stopped), "\(row.key)")
        }
        XCTAssertEqual(CueTable.row(for: .refused(.emergencyStop)).speech, [.stopped])
        let catalog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Resources/Speech.xcstrings")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: [String: Any]])
        func text(_ key: SpeechKey, _ language: String) -> String? {
            let localizations = strings[key.rawValue]?["localizations"] as? [String: [String: [String: String]]]
            return localizations?[language]?["stringUnit"]?["value"]
        }
        XCTAssertEqual(text(.driveStoppedHere, "en"), "Stopped here.")
        XCTAssertEqual(text(.driveStoppedHere, "zh-Hant"), "停在這裡。")
        XCTAssertEqual(text(.stopped, "en"), "Stopped.")
        XCTAssertEqual(text(.stopped, "zh-Hant"), "已急停。")
    }

    func testTheNewRefusalsAreP4() {
        let outside = CueTable.row(for: .refused(.outsideWorkArea))
        XCTAssertEqual(outside.haptic, .no)
        XCTAssertEqual(outside.speech, [.outside])
        XCTAssertEqual(outside.level, .p4)
        let noData = CueTable.row(for: .refused(.noArmData))
        XCTAssertEqual(noData.haptic, .no)
        XCTAssertEqual(noData.speech, [.noArmData])
        XCTAssertEqual(noData.level, .p4)
    }

    func testDriveEndConversionsAreTotal() {
        let byLink: [LetGoReason: DriveEnd] = [
            .tooFast: .tooFast, .tracking: .tracking, .noAnswer: .noAnswer, .watchdog: .linkHiccup,
            .lateRejection: .serverRefused,
        ]
        XCTAssertEqual(Set(byLink.keys), Set(LetGoReason.allCases))
        for reason in LetGoReason.allCases {
            XCTAssertEqual(DriveEnd(byLink: reason), byLink[reason], "\(reason)")
        }
        for refusal in Refusal.allCases {
            let end = DriveEnd(refused: refusal)
            switch refusal {
            case .emergencyStop: XCTAssertNil(end, "the alarm tells it")
            case .busy, .notReady: XCTAssertEqual(end, .serverBusy, "\(refusal)")
            case .serverRefused: XCTAssertEqual(end, .serverRefused)
            default: XCTAssertEqual(end, .unnamed, "\(refusal)")
            }
        }
    }

    /// A reason the server ends a hold with is told elsewhere exactly when, for a hold not yet accepted, the monitor
    /// emits nothing for it or a refusal that no drive ending names. So the `estop_active` branch stays in step with
    /// the monitor too.
    func testIsToldElsewhereMatchesTheMonitorsSilentReasons() {
        let others = [
            TeleopLink.successReason, "estop_active", "busy", "sim_not_ready", "invalid_rate_hz",
            "pose_watchdog_timeout",
        ]
        let reasons = others + FeedbackMonitor.emergencyStopReasons.sorted()
        for reason in reasons {
            var monitor = FeedbackMonitor(limits: GripperLimits(openDeg: 97, emptyDeg: 2))
            monitor.startSent(.pose, restart: false, at: 0)
            let events = monitor.startRefused(reason: reason, at: 20)
            var silent = events.isEmpty
            if events.count == 1, case .refused(let refusal) = events[0] {
                silent = DriveEnd(refused: refusal) == nil
            }
            XCTAssertEqual(FeedbackMonitor.isToldElsewhere(reason), silent, reason)
        }
        XCTAssertTrue(FeedbackMonitor.isToldElsewhere("estop_active"))
        XCTAssertFalse(FeedbackMonitor.isToldElsewhere("busy"))
    }
}
