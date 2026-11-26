import XCTest
@testable import TeleopCore

/// When the screen tells the operator to open the gripper before moving in: once an episode, on the first translation
/// that starts while the jaws are still closed as the episode began, and never while something is held, after a grip,
/// during a stop or while the simulator is paused or not responding.
final class JawsClosedReminderTests: XCTestCase {
    /// The S4 simulator's gripper numbers.
    private let limits = GripperLimits(openDeg: 95, emptyDeg: 5)
    private var rule: JawsClosedReminder!

    override func setUp() {
        rule = JawsClosedReminder(limits: limits)
    }

    private func look(
        jaws: GripperState? = .closed, degrees: Double? = 0, holding: Bool = false, gripping: Bool = false,
        stopped: Bool = false, simulatorHalted: Bool = false
    ) -> JawsClosedReminder.Look {
        JawsClosedReminder.Look(
            jaws: jaws, jawDeg: degrees, holding: holding, gripping: gripping, stopped: stopped,
            simulatorHalted: simulatorHalted)
    }

    /// The server starts every episode with the jaws closed (the build 32 trial: `gripper` "closed", 0 degrees).
    private func episodeStartState(_ episode: Int? = nil) -> ServerState {
        ServerState(gripper: .closed, activity: .ok, episode: episode, gripperDeg: 0)
    }

    func testItFiresOnceOnTheFirstMoveWithClosedJawsAfterAReset() {
        rule.sceneReset()
        rule.stateArrived(episodeStartState())
        XCTAssertTrue(rule.translationStarted(look()))
        XCTAssertFalse(rule.translationStarted(look()), "said once this episode")
        rule.stateArrived(episodeStartState())
        XCTAssertFalse(rule.translationStarted(look()), "still the same episode")
    }

    func testItDoesNotFireWithOpenJaws() {
        XCTAssertFalse(rule.translationStarted(look(jaws: .open, degrees: 60)))
        rule.sceneReset()
        rule.stateArrived(ServerState(gripper: .open, activity: .ok, gripperDeg: 60))
        XCTAssertFalse(rule.translationStarted(look(jaws: .open, degrees: 60)))
    }

    /// Opened once this episode, the operator knows the way: a later close and move is not this reminder's case.
    func testJawsSeenOpenThisEpisodeKeepItQuietUntilTheNextEpisode() {
        rule.stateArrived(episodeStartState())
        rule.stateArrived(ServerState(gripper: .open, activity: .gripperJogging, gripperDeg: 40))
        rule.stateArrived(ServerState(gripper: .closed, activity: .ok, gripperDeg: 2))
        XCTAssertFalse(rule.translationStarted(look(degrees: 2)))
        rule.sceneReset()
        rule.stateArrived(episodeStartState())
        XCTAssertTrue(rule.translationStarted(look()))
    }

    /// A state still showing the scene from before the reset says nothing about the new episode's jaws.
    func testAStateWhileResettingDoesNotCount() {
        rule.sceneReset()
        rule.stateArrived(ServerState(gripper: .open, activity: .resetting, gripperDeg: 60))
        rule.stateArrived(episodeStartState())
        XCTAssertTrue(rule.translationStarted(look()))
    }

    func testItDoesNotFireWhileHoldingOrAfterAGrip() {
        XCTAssertFalse(rule.translationStarted(look(degrees: 55, holding: true)), "the jaws hold the cube")
        XCTAssertFalse(rule.translationStarted(look(degrees: 55, gripping: true)), "a close just ended in contact")
        XCTAssertTrue(rule.translationStarted(look()), "neither held nor gripped: still armed")
    }

    func testItDoesNotFireDuringAStopOrAStallAndStaysArmed() {
        XCTAssertFalse(rule.translationStarted(look(stopped: true)))
        XCTAssertFalse(rule.translationStarted(look(simulatorHalted: true)))
        XCTAssertTrue(rule.translationStarted(look()), "nothing was said, so it is still owed")
    }

    func testAStateNamingAnotherEpisodeArmsItAgain() {
        rule.stateArrived(episodeStartState(7))
        XCTAssertTrue(rule.translationStarted(look()))
        rule.stateArrived(episodeStartState(7))
        XCTAssertFalse(rule.translationStarted(look()))
        rule.stateArrived(episodeStartState(8))
        XCTAssertTrue(rule.translationStarted(look()), "a new episode")
        rule.reconnected()
        rule.stateArrived(episodeStartState(3))
        XCTAssertTrue(rule.translationStarted(look()), "a restarted server counts again from its own number")
        rule.stateArrived(episodeStartState(3))
        XCTAssertFalse(rule.translationStarted(look()))
    }

    func testItFiresAgainAfterTheNextResetAndAfterAReconnect() {
        XCTAssertTrue(rule.translationStarted(look()))
        rule.sceneReset()
        XCTAssertTrue(rule.translationStarted(look()), "after a reset")
        rule.reconnected()
        XCTAssertTrue(rule.translationStarted(look()), "after a reconnect")
    }

    /// Closed is the server's jaws label: `closed` or `close` (`ServerState.gripperState`). Without a label, the angle
    /// decides by the robot profile's numbers; with neither, nothing is known and nothing is said.
    func testClosedIsDecidedFromTheLabelThenTheAngleNeverFromTheCube() {
        XCTAssertEqual(JawsClosedReminder.jawsClosed(.closed, degrees: nil, limits: limits), true)
        XCTAssertEqual(JawsClosedReminder.jawsClosed(.open, degrees: 0, limits: limits), false, "the label wins")
        XCTAssertEqual(JawsClosedReminder.jawsClosed(nil, degrees: 3, limits: limits), true)
        XCTAssertEqual(JawsClosedReminder.jawsClosed(nil, degrees: 40, limits: limits), false)
        XCTAssertNil(JawsClosedReminder.jawsClosed(nil, degrees: nil, limits: limits))
        XCTAssertFalse(rule.translationStarted(look(jaws: nil, degrees: nil)), "unknown jaws")
        XCTAssertTrue(rule.translationStarted(look(jaws: nil, degrees: 1)))
    }
}
