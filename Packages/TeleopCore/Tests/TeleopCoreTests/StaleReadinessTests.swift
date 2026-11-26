import XCTest
@testable import TeleopCore

final class StaleReadinessTests: XCTestCase {
    private func spoken(_ outputs: [CueOutput]) -> [SpeechKey] {
        outputs.flatMap { output -> [SpeechKey] in
            if case .speak(let phrases, _, _) = output { return phrases.map(\.key) }
            return []
        }
    }

    private func utterance(_ outputs: [CueOutput]) -> Int {
        outputs.compactMap { output in
            if case .speak(_, _, let id) = output { return id }
            return nil
        }.first!
    }

    func testQueuedReadinessDoesNotFollowEmergencyStop() {
        var scheduler = CueScheduler()
        _ = scheduler.raise(.takeSaved(count: 1), at: 0, currentHold: nil)
        _ = scheduler.raise(.ready, at: 10, currentHold: nil)
        let alarm = utterance(scheduler.raise(.emergencyStop(.button, takeDiscarded: false), at: 20, currentHold: nil))
        XCTAssertFalse(spoken(scheduler.speechFinished(id: alarm, at: 900)).contains(.ready))
    }

    func testQueuedReadinessDoesNotFollowConnectionLoss() {
        var scheduler = CueScheduler()
        _ = scheduler.raise(.takeSaved(count: 1), at: 0, currentHold: nil)
        _ = scheduler.raise(.ready, at: 10, currentHold: nil)
        let lost = utterance(scheduler.raise(.linkLost(holdEngaged: false), at: 20, currentHold: nil))
        XCTAssertFalse(spoken(scheduler.speechFinished(id: lost, at: 900)).contains(.ready))
    }

    func testOldQueuedReadinessExpiresWithoutDroppingHistoricalOutcome() {
        var scheduler = CueScheduler()
        let first = utterance(scheduler.raise(.takeDiscarded, at: 0, currentHold: nil))
        _ = scheduler.raise(.ready, at: 10, currentHold: nil)
        _ = scheduler.raise(.takeSaved(count: 2), at: 20, currentHold: nil)
        XCTAssertEqual(spoken(scheduler.speechFinished(id: first, at: 4000)), [.savedN])
    }
    func testInvalidatedReadinessCannotReviveWhenAvailabilityReturns() {
        var scheduler = CueScheduler()
        let first = utterance(scheduler.raise(.takeDiscarded, at: 0, currentHold: nil))
        _ = scheduler.raise(.ready, at: 10, currentHold: nil)
        _ = scheduler.updateReadiness(false, at: 20)
        _ = scheduler.updateReadiness(true, at: 30)
        XCTAssertTrue(scheduler.speechFinished(id: first, at: 900).isEmpty)
        XCTAssertEqual(spoken(scheduler.raise(.ready, at: 910, currentHold: nil)), [.ready])
    }

    func testInvalidationCancelsOnlyReadinessAndRetainsOutcomeOrder() {
        var scheduler = CueScheduler()
        let ready = utterance(scheduler.raise(.ready, at: 0, currentHold: nil))
        _ = scheduler.raise(.takeSaved(count: 2), at: 10, currentHold: nil)
        _ = scheduler.raise(.taskSuccess, at: 20, currentHold: nil)
        XCTAssertEqual(scheduler.updateReadiness(false, at: 30), [.stopSpeech(id: ready)])
        XCTAssertTrue(scheduler.speechFinished(id: ready, at: 40).isEmpty)
        let saved = scheduler.tick(at: 50, currentHold: nil)
        XCTAssertEqual(spoken(saved), [.savedN])
        XCTAssertEqual(spoken(scheduler.speechFinished(id: utterance(saved), at: 4000)), [.success])
    }

    func testExpiredReadinessDoesNotPlayThroughTimeoutPath() {
        var scheduler = CueScheduler()
        _ = scheduler.raise(.takeDiscarded, at: 0, currentHold: nil)
        _ = scheduler.raise(.ready, at: 10, currentHold: nil)
        _ = scheduler.raise(.offlineSaved(3), at: 20, currentHold: nil)
        XCTAssertEqual(spoken(scheduler.tick(at: 15000, currentHold: nil)), [.offlineSaved])
    }

    func testFreshReadinessQueuesAndPlaysNormally() {
        var scheduler = CueScheduler()
        let first = utterance(scheduler.raise(.takeDiscarded, at: 0, currentHold: nil))
        _ = scheduler.raise(.ready, at: 10, currentHold: nil)
        XCTAssertEqual(spoken(scheduler.speechFinished(id: first, at: 900)), [.ready])
    }

    func testAudioEngineDelayedStartCannotReviveExpiredReadiness() {
        var scheduler = CueScheduler()
        let ready = utterance(scheduler.raise(.ready, at: 0, currentHold: nil))
        XCTAssertEqual(scheduler.speechWillStart(id: ready, at: 2000), [.stopSpeech(id: ready)])
        XCTAssertTrue(scheduler.speechFinished(id: ready, at: 2100).isEmpty)
        XCTAssertEqual(spoken(scheduler.raise(.ready, at: 2200, currentHold: nil)), [.ready])
    }

    func testInvalidationNeverCancelsTheEmergencyAlarm() {
        var scheduler = CueScheduler()
        let alarm = utterance(scheduler.raise(.emergencyStop(.button, takeDiscarded: false), at: 0, currentHold: nil))
        XCTAssertTrue(scheduler.updateReadiness(false, at: 10).isEmpty)
        XCTAssertTrue(scheduler.speechWillStart(id: alarm, at: 3000).isEmpty)
    }

    func testQueuedLatchIsCancelledWhenTheMoveEndsNormally() {
        for ending in [DriveCue.arrived, .stoppedByYou, .stoppedByYouTapOnce, .ended(.timeLimit)] {
            var scheduler = CueScheduler()
            let saved = utterance(scheduler.raise(.takeSaved(count: 1), at: 0, currentHold: nil))
            _ = scheduler.raise(.drive(.latched), at: 10, currentHold: 4)
            _ = scheduler.raise(.drive(ending), at: 20, currentHold: nil)
            let next = spoken(scheduler.speechFinished(id: saved, at: 900))
            XCTAssertFalse(next.contains(.driveLocked), "\(ending)")
            XCTAssertEqual(next, CueTable.phrases(for: .drive(ending)).map(\.key), "\(ending)")
        }
    }

    func testActiveLatchIsCancelledBeforeTheEndingStarts() {
        var scheduler = CueScheduler()
        let latch = utterance(scheduler.raise(.drive(.latched), at: 0, currentHold: 4))
        let ended = scheduler.raise(.drive(.stoppedByYou), at: 10, currentHold: nil)
        XCTAssertTrue(ended.contains(.stopSpeech(id: latch)))
        XCTAssertEqual(spoken(ended), [.driveStoppedHere])
        XCTAssertTrue(scheduler.speechFinished(id: latch, at: 20).isEmpty)
    }

    func testTimedOutSubmittedReadinessIsCancelledBeforeTheNextUtterance() {
        var scheduler = CueScheduler()
        let ready = utterance(scheduler.raise(.ready, at: 0, currentHold: nil))
        _ = scheduler.raise(.takeSaved(count: 1), at: 10, currentHold: nil)
        let output = scheduler.tick(at: 15000, currentHold: nil)
        XCTAssertEqual(output.first, .stopSpeech(id: ready))
        XCTAssertEqual(spoken(output), [.savedN])
        XCTAssertTrue(scheduler.speechWillStart(id: ready, at: 15010).isEmpty)
        XCTAssertTrue(scheduler.speechFinished(id: ready, at: 15020).isEmpty)
    }

}
