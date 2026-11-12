import TeleopCore
import XCTest

/// The recorder narration in the orders the real server sends its states, which the server model does not copy
/// exactly (interaction specification §6.2 to §6.7).
final class RecorderNarratorTests: XCTestCase {
    private var narrator = RecorderNarrator()

    override func setUp() {
        narrator = RecorderNarrator()
        narrator.welcomed(session: "run")
    }

    private func rec(_ label: RecorderLabel, saved: Int = 4, discarded: Int = 0) -> RecorderStatus {
        RecorderStatus(label: label, saved: saved, discarded: discarded)
    }

    private func see(_ state: ServerState, moving: Bool = false, at now: Int) -> [FeedbackEvent] {
        narrator.observe(state, moving: moving, at: now) + narrator.tick(at: now)
    }

    /// The real server sends the state that follows `ok scene_reset` with the new episode but the recorder fields
    /// of the take it threw away; they are refreshed one loop pass later.
    func testAResetThatDiscardsATakeSaysDiscardedThenReady() {
        _ = see(ServerState(taskSuccess: false, episode: 1, recorder: rec(.armed)), at: 0)
        _ = see(ServerState(taskSuccess: false, episode: 1, recorder: rec(.capturing)), moving: true, at: 200)
        var heard = see(ServerState(activity: .ok, taskSuccess: false, episode: 2, recorder: rec(.capturing)), at: 3000)
        heard += see(
            ServerState(activity: .ok, taskSuccess: false, episode: 2, recorder: rec(.armed, discarded: 1)), at: 3200)
        heard += see(
            ServerState(activity: .ok, taskSuccess: false, episode: 2, recorder: rec(.armed, discarded: 1)), at: 3400)
        XCTAssertEqual(heard, [.takeDiscarded, .ready])
    }

    /// E12 needs `rec` not capturing: a new episode or a connection onto a take being captured says "Ready." only
    /// once nothing is captured.
    func testNeverReadyWhileATakeIsCaptured() {
        narrator = RecorderNarrator()
        narrator.welcomed(session: "run")
        XCTAssertEqual(see(ServerState(episode: 1, recorder: rec(.capturing)), at: 0), [.recordingSession(saved: 4)])
        XCTAssertEqual(see(ServerState(episode: 1, recorder: rec(.capturing)), at: 200), [])
        XCTAssertEqual(see(ServerState(episode: 2, recorder: rec(.capturing, discarded: 1)), at: 400), [.takeDiscarded])
        XCTAssertEqual(see(ServerState(episode: 2, recorder: rec(.armed, discarded: 1)), at: 600), [.ready])
        XCTAssertEqual(see(ServerState(episode: 2, recorder: rec(.armed, discarded: 1)), at: 800), [], "once")
    }

    /// The stop that the reconnect finds already counted its own discard: a later discard is still told.
    func testAReconnectOntoAStopDoesNotSwallowALaterDiscard() {
        _ = see(ServerState(episode: 1, recorder: rec(.armed)), at: 0)
        _ = see(ServerState(episode: 1, recorder: rec(.capturing)), moving: true, at: 200)
        narrator.linkLost()
        narrator.welcomed(session: "run")
        XCTAssertEqual(see(ServerState(estop: true, episode: 1, recorder: rec(.off, discarded: 1)), at: 5000), [])
        XCTAssertTrue(narrator.stopDiscardsTake, "the stop says the take was discarded")
        XCTAssertEqual(see(ServerState(episode: 2, recorder: rec(.off, discarded: 1)), at: 9000), [.ready])
        _ = see(ServerState(episode: 2, recorder: rec(.armed, discarded: 1)), at: 9200)
        _ = see(ServerState(episode: 2, recorder: rec(.capturing, discarded: 1)), moving: true, at: 10_000)
        XCTAssertEqual(
            see(ServerState(episode: 3, recorder: rec(.armed, discarded: 2)), at: 15_000), [.takeDiscarded, .ready])
    }

    /// The stop the app sends first after a reconnect: its discard shows in a later state and is the stop's.
    func testAStopSentOnReconnectStillAbsorbsItsDiscard() {
        _ = see(ServerState(episode: 1, recorder: rec(.capturing)), moving: true, at: 0)
        narrator.linkLost()
        narrator.welcomed(session: "run")
        narrator.emergencyStopLearned()
        XCTAssertEqual(see(ServerState(episode: 1, recorder: rec(.capturing)), at: 3000), [])
        XCTAssertEqual(see(ServerState(estop: true, episode: 1, recorder: rec(.off, discarded: 1)), at: 3200), [])
    }

    /// On the real server the success display lasts 1.5 s, less than the 2 s wait for a save: the automatic reset
    /// settles it, and "Success, but not saved." comes before "Ready.".
    func testASuccessNotSavedIsToldBeforeTheAutomaticResetsReady() {
        _ = see(ServerState(taskSuccess: false, episode: 1, recorder: rec(.off)), at: 0)
        XCTAssertEqual(
            see(ServerState(activity: .taskSuccess, taskSuccess: true, episode: 1, recorder: rec(.off)), at: 1000), [])
        XCTAssertEqual(narrator.display.mode, .waiting)
        XCTAssertEqual(
            see(ServerState(activity: .taskSuccess, taskSuccess: true, episode: 1, recorder: rec(.off)), at: 1200), [])
        XCTAssertEqual(
            see(ServerState(activity: .ok, taskSuccess: false, episode: 2, recorder: rec(.off)), at: 2500),
            [.successNotSaved, .ready])
        XCTAssertEqual(
            see(ServerState(activity: .ok, taskSuccess: false, episode: 2, recorder: rec(.armed)), at: 3600), [])
    }

    /// A take too short to save is discarded at the success: that settles it at once, and the discard is not told
    /// on its own.
    func testATakeTooShortToSaveIsToldAsNotSavedAtOnce() {
        _ = see(ServerState(taskSuccess: false, episode: 1, recorder: rec(.capturing)), at: 0)
        XCTAssertEqual(
            see(
                ServerState(activity: .taskSuccess, taskSuccess: true, episode: 1, recorder: rec(.capturing)), at: 1000),
            [])
        XCTAssertEqual(
            see(
                ServerState(activity: .taskSuccess, taskSuccess: true, episode: 1, recorder: rec(.off, discarded: 1)),
                at: 1200),
            [.successNotSaved])
        XCTAssertEqual(
            see(
                ServerState(activity: .ok, taskSuccess: false, episode: 2, recorder: rec(.armed, discarded: 1)),
                at: 2500),
            [.ready])
    }

    /// §6.7: only the same episode is the take that continues; a new one while the link was down owes "Ready.".
    func testAReconnectOntoANewEpisodeOwesReadyNotTheTakeContinues() {
        _ = see(ServerState(episode: 1, recorder: rec(.capturing)), moving: true, at: 0)
        narrator.linkLost()
        narrator.welcomed(session: "run")
        XCTAssertEqual(
            see(ServerState(episode: 2, recorder: rec(.capturing, discarded: 1)), at: 5000),
            [.reconnected, .offlineDiscarded(1)])
        XCTAssertEqual(see(ServerState(episode: 2, recorder: rec(.armed, discarded: 1)), at: 5200), [.ready])
    }

    /// A success whose answer was still open when the link dropped is told after the reconnect.
    func testASuccessStillWaitingForItsSaveIsJudgedAfterAReconnect() {
        _ = see(ServerState(taskSuccess: false, episode: 1, recorder: rec(.off)), at: 0)
        _ = see(ServerState(activity: .taskSuccess, taskSuccess: true, episode: 1, recorder: rec(.off)), at: 1000)
        narrator.linkLost()
        narrator.welcomed(session: "run")
        XCTAssertEqual(
            see(ServerState(episode: 2, recorder: rec(.armed)), at: 6000), [.reconnected, .successNotSaved, .ready])

        narrator = RecorderNarrator()
        narrator.welcomed(session: "run")
        _ = see(ServerState(taskSuccess: false, episode: 1, recorder: rec(.capturing)), at: 0)
        _ = see(ServerState(activity: .taskSuccess, taskSuccess: true, episode: 1, recorder: rec(.capturing)), at: 1000)
        narrator.linkLost()
        narrator.welcomed(session: "run")
        XCTAssertEqual(
            see(ServerState(episode: 2, recorder: rec(.armed, saved: 5)), at: 6000),
            [.reconnected, .offlineSaved(1), .ready],
            "saved after all")
    }
}
