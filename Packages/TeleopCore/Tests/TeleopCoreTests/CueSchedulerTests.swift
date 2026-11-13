import XCTest
@testable import TeleopCore

/// Which cue wins (interaction specification §5.4, C-F3).
final class CueSchedulerTests: XCTestCase {
    private var scheduler = CueScheduler()

    override func setUp() {
        scheduler = CueScheduler()
    }

    private func haptics(_ outputs: [CueOutput]) -> [Haptic] {
        outputs.compactMap { if case .haptic(let haptic) = $0 { return haptic } else { return nil } }
    }

    private func speech(_ outputs: [CueOutput]) -> [(keys: [SpeechKey], interrupt: Bool, id: Int)] {
        outputs.compactMap {
            if case .speak(let phrases, let interrupt, let id) = $0 {
                return (phrases.map(\.key), interrupt, id)
            } else {
                return nil
            }
        }
    }

    func testAHigherCuePreemptsALowerOne() {
        XCTAssertEqual(haptics(scheduler.raise(.limit(.workspace), at: 0, currentHold: nil)), [.end])
        XCTAssertEqual(
            haptics(scheduler.raise(.emergencyStop(.button, takeDiscarded: false), at: 100, currentHold: nil)), [.alarm]
        )
    }

    func testALowerCueArrivingWhileAHigherPlaysIsDropped() {
        _ = scheduler.raise(.letGo(.tooFast), at: 0, currentHold: nil)
        XCTAssertEqual(haptics(scheduler.raise(.limit(.blocked), at: 100, currentHold: nil)), [])
        XCTAssertTrue(scheduler.log.last!.dropped)
        XCTAssertEqual(haptics(scheduler.tick(at: 900, currentHold: nil)), [], "a dropped cue never comes back")
    }

    func testGoWaitsForAHigherCueAndPlaysWhenItEnds() {
        _ = scheduler.raise(.limit(.workspace), at: 0, currentHold: 7)
        XCTAssertEqual(haptics(scheduler.raise(.holdLive(hold: 7), at: 50, currentHold: 7)), [])
        XCTAssertEqual(haptics(scheduler.tick(at: 300, currentHold: 7)), [], "END still plays")
        XCTAssertEqual(haptics(scheduler.tick(at: 380, currentHold: 7)), [.go], "END is 380 ms long")
    }

    /// ON TARGET sits between END and GO: GO waits for it, END cuts it short, and it goes into the cue log.
    func testOnTargetPlaysAboveGoAndBelowEnd() {
        XCTAssertEqual(haptics(scheduler.raise(.onTarget, at: 0, currentHold: 2)), [.onTarget])
        XCTAssertEqual(
            scheduler.log.last,
            CueLogEntry(atMs: 0, event: .onTarget, haptic: .onTarget, sound: nil, speech: [], dropped: false))
        XCTAssertEqual(haptics(scheduler.raise(.holdLive(hold: 2), at: 100, currentHold: 2)), [])
        XCTAssertEqual(haptics(scheduler.tick(at: 349, currentHold: 2)), [])
        XCTAssertEqual(haptics(scheduler.tick(at: 350, currentHold: 2)), [.go])
        XCTAssertEqual(haptics(scheduler.raise(.onTarget, at: 1000, currentHold: nil)), [.onTarget])
        XCTAssertEqual(haptics(scheduler.raise(.limit(.blocked), at: 1100, currentHold: nil)), [.end])
        _ = scheduler.raise(.limit(.workspace), at: 2000, currentHold: nil)
        XCTAssertEqual(haptics(scheduler.raise(.onTarget, at: 2100, currentHold: nil)), [], "dropped under END")
    }

    func testGoNeverWaitsLongerThan400Ms() {
        _ = scheduler.raise(.letGo(.watchdog), at: 0, currentHold: 3)
        _ = scheduler.raise(.holdLive(hold: 3), at: 10, currentHold: 3)
        XCTAssertEqual(haptics(scheduler.tick(at: 409, currentHold: 3)), [])
        XCTAssertEqual(haptics(scheduler.tick(at: 410, currentHold: 3)), [.go])
    }

    /// "GO only for its own hold": a GO still waiting when its hold ended is never played.
    func testAWaitingGoIsDroppedWhenItsHoldHasEnded() {
        _ = scheduler.raise(.refused(.deadInput), at: 0, currentHold: 4)
        _ = scheduler.raise(.holdLive(hold: 4), at: 20, currentHold: 4)
        XCTAssertEqual(haptics(scheduler.tick(at: 300, currentHold: nil)), [])
        XCTAssertEqual(haptics(scheduler.tick(at: 500, currentHold: 5)), [])
        XCTAssertFalse(scheduler.needsTicks)
    }

    func testGoForAHoldThatIsNoLongerEngagedIsNotPlayed() {
        XCTAssertEqual(haptics(scheduler.raise(.holdLive(hold: 1), at: 0, currentHold: 2)), [])
        XCTAssertEqual(haptics(scheduler.raise(.holdLive(hold: 2), at: 0, currentHold: 2)), [.go])
    }

    func testTheSameCueNeverRepeatsWithin300Ms() {
        XCTAssertEqual(haptics(scheduler.raise(.refused(.deadInput), at: 0, currentHold: nil)), [.no])
        XCTAssertEqual(haptics(scheduler.raise(.refused(.deadInput), at: 299, currentHold: nil)), [])
        XCTAssertEqual(haptics(scheduler.raise(.refused(.deadInput), at: 300, currentHold: nil)), [.no])
    }

    /// C-F3: GO is never dropped. A quick release and press makes the next hold's GO come within 300 ms of the
    /// last one; it waits out the repeat gap instead.
    func testAGoWithin300MsOfTheLastOneWaitsInsteadOfBeingDropped() {
        XCTAssertEqual(haptics(scheduler.raise(.holdLive(hold: 1), at: 0, currentHold: 1)), [.go])
        XCTAssertEqual(haptics(scheduler.raise(.holdLive(hold: 2), at: 190, currentHold: 2)), [])
        XCTAssertFalse(scheduler.log.last!.dropped)
        XCTAssertEqual(haptics(scheduler.tick(at: 299, currentHold: 2)), [])
        XCTAssertEqual(haptics(scheduler.tick(at: 300, currentHold: 2)), [.go])
    }

    func testSoundsAlwaysPlay() {
        _ = scheduler.raise(.emergencyStop(.button, takeDiscarded: false), at: 0, currentHold: nil)
        XCTAssertTrue(scheduler.raise(.takeDiscarded, at: 10, currentHold: nil).contains(.sound(.discarded)))
    }

    func testEmergencyStopAndLinkLostInterruptSpeech() {
        let first = speech(scheduler.raise(.takeSaved(count: 3), at: 0, currentHold: nil))
        XCTAssertEqual(first.map(\.interrupt), [false])
        let stop = speech(scheduler.raise(.emergencyStop(.behind, takeDiscarded: true), at: 100, currentHold: nil))
        XCTAssertEqual(stop.map(\.interrupt), [true])
        XCTAssertEqual(stop.first?.keys, [.estop, .causeBehind, .takeDiscarded, .resetPrompt])
        // The cut-off utterance reports its end late; that must not free the voice the stop is using.
        XCTAssertTrue(scheduler.speechFinished(id: first[0].id, at: 110).isEmpty)
        XCTAssertTrue(speech(scheduler.raise(.refused(.emergencyStop), at: 120, currentHold: nil)).isEmpty)
    }

    func testRecorderNewsIsQueuedAndNeverDropped() {
        let first = speech(scheduler.raise(.takeDiscarded, at: 0, currentHold: nil))
        XCTAssertTrue(speech(scheduler.raise(.ready, at: 10, currentHold: nil)).isEmpty)
        XCTAssertTrue(scheduler.needsTicks)
        XCTAssertEqual(speech(scheduler.speechFinished(id: first[0].id, at: 900)).map(\.keys), [[.ready]])
    }

    func testReasonsAreDroppedWhileSomethingIsSpokenButTheirHapticPlays() {
        _ = scheduler.raise(.ready, at: 0, currentHold: nil)
        let outputs = scheduler.raise(.limit(.blocked), at: 50, currentHold: nil)
        XCTAssertEqual(haptics(outputs), [.end])
        XCTAssertTrue(speech(outputs).isEmpty)
        XCTAssertEqual(scheduler.log.last?.speech, [])
    }

    func testEachRefusalReasonIsSpokenAtMostOnceEvery3s() {
        let first = speech(scheduler.raise(.refused(.noLink), at: 0, currentHold: nil))
        XCTAssertEqual(first.map(\.keys), [[.noLink]])
        _ = scheduler.speechFinished(id: first[0].id, at: 500)
        let again = scheduler.raise(.refused(.noLink), at: 1000, currentHold: nil)
        XCTAssertEqual(haptics(again), [.no], "the press is still answered")
        XCTAssertTrue(speech(again).isEmpty)
        XCTAssertEqual(speech(scheduler.raise(.refused(.noLink), at: 3000, currentHold: nil)).map(\.keys), [[.noLink]])
    }

    /// A STOP that has reached no robot is said after "Link lost.", never dropped under it, nor under the alarm's own
    /// words (J7).
    func testNotStoppedWaitsForTheVoiceAndIsNeverDropped() {
        let alarm = speech(scheduler.raise(.emergencyStop(.button, takeDiscarded: false), at: 0, currentHold: nil))
        let lost = speech(scheduler.raise(.linkLost(holdEngaged: false), at: 2700, currentHold: nil))
        XCTAssertEqual(lost.map(\.keys), [[.linkLost]])
        XCTAssertTrue(scheduler.speechFinished(id: alarm[0].id, at: 2710).isEmpty, "the alarm's words were cut off")
        let refused = scheduler.raise(.refused(.notStopped), at: 2720, currentHold: nil)
        XCTAssertEqual(haptics(refused), [.no], "the alarm's rattle has ended")
        XCTAssertTrue(speech(refused).isEmpty, "not over Link lost.")
        XCTAssertEqual(scheduler.log.last?.speech, [.notStopped])
        XCTAssertEqual(scheduler.log.last?.dropped, false)
        XCTAssertEqual(speech(scheduler.speechFinished(id: lost[0].id, at: 3500)).map(\.keys), [[.notStopped]])
    }

    /// A "No link. Not stopped." still waiting when the phone announces an emergency stop, as when the owed STOP goes out
    /// at a quick reconnect, is no longer said: it would follow the alarm's words and contradict them. Other news waits.
    func testAnEmergencyStopDropsAWaitingNotStoppedButNoOtherNews() {
        let lost = speech(scheduler.raise(.linkLost(holdEngaged: false), at: 0, currentHold: nil))
        _ = scheduler.raise(.refused(.notStopped), at: 10, currentHold: nil)
        _ = scheduler.raise(.takeDiscarded, at: 20, currentHold: nil)
        let alarm = speech(scheduler.raise(.emergencyStop(.button, takeDiscarded: false), at: 300, currentHold: nil))
        XCTAssertEqual(alarm.map(\.interrupt), [true])
        XCTAssertTrue(scheduler.speechFinished(id: lost[0].id, at: 310).isEmpty)
        let next = speech(scheduler.speechFinished(id: alarm[0].id, at: 4000))
        XCTAssertEqual(next.map(\.keys), [[.takeDiscarded]])
        XCTAssertTrue(scheduler.speechFinished(id: next[0].id, at: 5000).isEmpty, "nothing else waits")
    }

    /// The dropped "No link. Not stopped." was never said: one raised soon after, as when the connection that took the
    /// owed STOP fails right after its welcome, is said after the alarm's words, not kept quiet as a repeat.
    func testANotStoppedDroppedByTheAlarmDoesNotSilenceTheNextOne() {
        let lost = speech(scheduler.raise(.linkLost(holdEngaged: false), at: 0, currentHold: nil))
        _ = scheduler.raise(.refused(.notStopped), at: 10, currentHold: nil)
        let alarm = speech(scheduler.raise(.emergencyStop(.button, takeDiscarded: false), at: 1500, currentHold: nil))
        XCTAssertTrue(scheduler.speechFinished(id: lost[0].id, at: 1510).isEmpty, "the first one was dropped")
        _ = scheduler.raise(.refused(.notStopped), at: 2500, currentHold: nil)
        XCTAssertEqual(scheduler.log.last?.speech, [.notStopped])
        XCTAssertEqual(speech(scheduler.speechFinished(id: alarm[0].id, at: 4000)).map(\.keys), [[.notStopped]])
    }

    func testADeadInputIsFeltButNotSpoken() {
        let outputs = scheduler.raise(.refused(.deadInput), at: 0, currentHold: nil)
        XCTAssertEqual(outputs, [.haptic(.no)])
    }

    func testAnUnreportedEndOfSpeechDoesNotSilenceTheAppForever() {
        _ = scheduler.raise(.ready, at: 0, currentHold: nil)
        _ = scheduler.raise(.takeDiscarded, at: 10, currentHold: nil)
        XCTAssertEqual(speech(scheduler.tick(at: 15_000, currentHold: nil)).map(\.keys), [[.takeDiscarded]])
    }

    func testStoppingHapticsForgetsAWaitingGo() {
        _ = scheduler.raise(.emergencyStop(.button, takeDiscarded: false), at: 0, currentHold: 1)
        _ = scheduler.raise(.holdLive(hold: 1), at: 10, currentHold: 1)
        XCTAssertEqual(scheduler.stopHaptics(), [.stopHaptics])
        XCTAssertEqual(haptics(scheduler.tick(at: 500, currentHold: 1)), [])
        XCTAssertEqual(
            haptics(scheduler.raise(.limit(.wrist), at: 520, currentHold: nil)), [.end], "nothing plays any more")
    }
}
