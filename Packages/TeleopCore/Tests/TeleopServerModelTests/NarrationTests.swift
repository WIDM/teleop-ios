import Foundation
import TeleopCore
import XCTest
@testable import TeleopServerModel

/// The recorder narration (`RecorderNarrator`) driven by the states a listening connection gets from the server
/// model with the recorder on: what the phone says per take (interaction specification §6.2, §6.3, §6.5, §6.7).
final class NarrationTests: XCTestCase {
    private var bench: Bench!
    private var phone: Bench.Client!
    private var observer: Bench.Client!
    private var narrator = RecorderNarrator()
    private var heard: [FeedbackEvent] = []
    /// When each event was raised, and when the first state with `task_success` true came.
    private var heardAt: [(atMs: Int, event: FeedbackEvent)] = []
    private var successAt: Int?
    private var read = 0
    /// The phone has a hold engaged.
    private var moving = false
    /// While false, states are not handed on, as during a link drop.
    private var linkUp = true

    override func setUp() {
        bench = Bench(.s4Simulator(stepsPerSecond: 17, recorder: .init(savedAtStart: 4)))
        phone = bench.client()
        narrator = RecorderNarrator()
        heard = []
        connect()
    }

    /// A new listening connection, and the control connection's welcome.
    private func connect() {
        observer = bench.client()
        read = 0
        linkUp = true
        narrator.welcomed(session: bench.config.session)
        bench.wait(0.5)
        pump()
    }

    private func dropLink() {
        pump()
        narrator.linkLost()
        observer.close()
        linkUp = false
    }

    /// Hands the narrator every state the listening connection got since the last call, at the time it came.
    private func pump() {
        guard linkUp else { return }
        let all = observer.received
        for output in all[read...] {
            guard let state = serverState(output) else { continue }
            let at = Int((output.time * 1000).rounded())
            if state.taskSuccess == true, successAt == nil { successAt = at }
            let events = narrator.observe(state, moving: moving, at: at) + narrator.tick(at: at)
            heard += events
            heardAt += events.map { (at, $0) }
        }
        read = all.count
    }

    private func wait(_ seconds: Double) {
        bench.wait(seconds)
        pump()
    }

    /// The states that come while `body` runs are handed on as seen with a hold engaged.
    private func take(_ body: () -> Void) {
        moving = true
        body()
        pump()
        moving = false
    }

    func testConnectingToARecordingServerSaysSoAndIsReady() {
        XCTAssertEqual(heard, [.recordingSession(saved: 4), .ready])
        XCTAssertEqual(narrator.display, RecorderDisplay(mode: .armed, saved: 4, discarded: 0))
    }

    func testASavedTake() {
        heard = []
        take { phone.carryCubeOntoGoal() }
        XCTAssertEqual(narrator.display.mode, .capturing)
        XCTAssertGreaterThan(narrator.display.secondsCaptured ?? 0, 1)
        take { phone.gripperJog("open", seconds: 3, release: false) }
        wait(0.2)
        XCTAssertEqual(heard, [.takeSaved(count: 5)])
        XCTAssertEqual(narrator.display.mode, .waiting, "never 'reset to record' while the success shows")
        wait(10)
        XCTAssertEqual(heard, [.takeSaved(count: 5), .ready])
        XCTAssertEqual(narrator.display, RecorderDisplay(mode: .armed, saved: 5, discarded: 0))
    }

    /// The emergency stop speaks of the discarded take itself; the counter's rise is not told again.
    func testATakeDiscardedByAnEmergencyStop() {
        heard = []
        take { phone.gripperJog("open", seconds: 1) }
        XCTAssertEqual(narrator.recorder?.label, .capturing)
        XCTAssertTrue(narrator.stopDiscardsTake)
        phone.send("estop")
        narrator.emergencyStopLearned()
        wait(1)
        XCTAssertEqual(narrator.recorder?.discarded, 1)
        XCTAssertTrue(narrator.stopDiscardsTake, "still the take the stop interrupted")
        XCTAssertEqual(narrator.display.mode, .off)
        phone.send("reset_scene")
        wait(4)
        XCTAssertEqual(heard, [.ready], "no second 'Take discarded.'")
        XCTAssertEqual(narrator.display, RecorderDisplay(mode: .armed, saved: 4, discarded: 1))
        XCTAssertFalse(narrator.stopDiscardsTake)
    }

    /// A stop the app only learns from a state (the server stopped the arm) is handled the same way.
    func testAServerStopSeenOnlyInAStateAlsoAbsorbsTheDiscard() {
        heard = []
        take { phone.gripperJog("open", seconds: 1) }
        bench.model.engageEstop()
        wait(1)
        XCTAssertTrue(narrator.stopDiscardsTake)
        XCTAssertEqual(heard, [])
    }

    func testATakeDiscardedByAReset() {
        heard = []
        take { phone.gripperJog("open", seconds: 1) }
        phone.send("reset_scene")
        wait(4)
        XCTAssertEqual(heard, [.takeDiscarded, .ready])
    }

    func testAResetBeforeAnythingWasCapturedIsJustReady() {
        heard = []
        phone.send("reset_scene")
        wait(4)
        XCTAssertEqual(heard, [.ready])
    }

    /// After an emergency stop released without a reset the recorder stays off: moving says so once, and the next
    /// success is reported as not saved.
    func testASuccessWhileTheRecorderIsOff() throws {
        phone.send("estop")
        wait(0.5)
        phone.send("estop_reset")
        wait(0.5)
        heard = []
        XCTAssertEqual(narrator.recorder?.label, .off)
        take { phone.carryCubeOntoGoal() }
        XCTAssertEqual(heard, [.notRecording], "once per take, not once per state")
        heard = []
        take { phone.gripperJog("open", seconds: 3, release: false) }
        wait(2.5)
        XCTAssertEqual(heard, [.successNotSaved])
        let said = try XCTUnwrap(heardAt.last { $0.event == .successNotSaved }?.atMs)
        let success = try XCTUnwrap(successAt)
        XCTAssertGreaterThanOrEqual(said - success, RecorderNarrator.notSavedWaitMs, "the save might still have come")
        XCTAssertLessThan(said - success, RecorderNarrator.notSavedWaitMs + 300)
        wait(10)
        XCTAssertEqual(heard, [.successNotSaved, .ready])
        XCTAssertEqual(narrator.display, RecorderDisplay(mode: .armed, saved: 4, discarded: 0))
    }

    /// The take is saved while the link is down. On the reconnect to the same server run the counters are compared.
    func testALinkDropAcrossASave() {
        take { phone.carryCubeOntoGoal() }
        heard = []
        dropLink()
        phone.gripperJog("open", seconds: 3, release: false)
        bench.wait(10)
        connect()
        XCTAssertEqual(heard, [.reconnected, .offlineSaved(1), .ready])
        XCTAssertEqual(narrator.display, RecorderDisplay(mode: .armed, saved: 5, discarded: 0))
    }

    func testALinkDropInTheMiddleOfATakeContinuesIt() {
        take { phone.gripperJog("open", seconds: 1) }
        heard = []
        dropLink()
        bench.wait(2)
        connect()
        XCTAssertEqual(heard, [.reconnected, .takeContinues], "never 'Ready.' with a take capturing")
    }

    /// The control socket closed during the take: the server stopped, the take is gone. The stop's own event tells
    /// it, so the reconnect adds nothing, and the stop says the take was discarded.
    func testAStopDuringALinkDropIsLeftToTheStop() {
        take { phone.gripperJog("open", seconds: 1) }
        heard = []
        dropLink()
        bench.model.engageEstop()
        bench.wait(1)
        connect()
        XCTAssertEqual(heard, [])
        XCTAssertTrue(narrator.stopDiscardsTake)
        phone.send("reset_scene")
        wait(4)
        XCTAssertEqual(heard, [.ready], "the discard was the stop's")
    }

    func testANewServerRunIsSaid() {
        heard = []
        dropLink()
        narrator.welcomed(session: "another run")
        observer = bench.client()
        read = 0
        linkUp = true
        wait(0.5)
        XCTAssertEqual(heard, [.reconnected, .serverRestarted, .recordingSession(saved: 4), .ready])
    }
}

/// Servers without a recorder, and servers that do not say.
final class NarrationWithoutRecorderTests: XCTestCase {
    private func run(_ config: ServerModelConfig, dropRecKey: Bool) -> (heard: [FeedbackEvent], display: RecorderDisplay) {
        let bench = Bench(config)
        let phone = bench.client()
        let observer = bench.client()
        var narrator = RecorderNarrator()
        narrator.welcomed(session: config.session)
        bench.wait(0.5)
        phone.carryCubeOntoGoal()
        phone.gripperJog("open", seconds: 3, release: false)
        bench.wait(10)
        var heard: [FeedbackEvent] = []
        for output in observer.received {
            guard var state = serverState(output) else { continue }
            if dropRecKey { state.recorder = nil }
            let at = Int((output.time * 1000).rounded())
            heard += narrator.observe(state, moving: false, at: at) + narrator.tick(at: at)
        }
        return (heard, narrator.display)
    }

    func testASuccessWithoutARecorderIsJustSuccess() {
        let result = run(.s4Simulator(stepsPerSecond: 17), dropRecKey: false)
        XCTAssertEqual(result.heard, [.ready, .taskSuccess, .ready])
        XCTAssertEqual(result.display, RecorderDisplay(mode: .notRecording))
    }

    /// No `rec` key: the recorder is unknown, never "no recorder", and nothing about takes is said.
    func testAnUnknownServerSaysSuccessAndShowsNoRecorder() {
        let result = run(.s4Simulator(stepsPerSecond: 17, recorder: .init()), dropRecKey: true)
        XCTAssertEqual(result.heard, [.ready, .taskSuccess, .ready])
        XCTAssertEqual(result.display, .unknown)
    }

    func testTheStopStateOffersOnlyAResetWhenThereIsARecorder() {
        XCTAssertEqual(StopExits.offered(recorder: RecorderStatus(label: .armed)).exits, [.resetScene])
        XCTAssertEqual(StopExits.offered(recorder: RecorderStatus(label: .off)).exits, [.resetScene])
        XCTAssertEqual(StopExits.offered(recorder: RecorderStatus(label: .none)),
                       StopExits(exits: [.resetScene, .releaseKeepScene], recordingMayStayOff: false))
        XCTAssertEqual(StopExits.offered(recorder: nil),
                       StopExits(exits: [.resetScene, .releaseKeepScene], recordingMayStayOff: true))
        XCTAssertEqual(StopExits.offered(recorder: nil, practice: true).recordingMayStayOff, false)
    }
}
