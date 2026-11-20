import XCTest
@testable import TeleopCore

/// Holding an object: set by the server's contact for the last close, cleared by an open the server runs, a scene reset
/// (asked for, or a new episode in a state) and a reconnect; an emergency stop keeps it. While it holds, every pad hold
/// takes the gripper link's path.
final class ObjectHoldTests: XCTestCase {
    private func held() -> ObjectHold {
        var hold = ObjectHold()
        hold.apply(.contactReported)
        XCTAssertTrue(hold.holding)
        return hold
    }

    func testNothingIsHeldAtFirst() {
        XCTAssertFalse(ObjectHold().holding)
    }

    func testAResetOrAReconnectLetsGo() {
        for change in [ObjectHold.Change.sceneReset, .reconnected] {
            var hold = held()
            hold.apply(change)
            XCTAssertFalse(hold.holding, "\(change)")
        }
    }

    /// An open lets go once the server shows it opening the jaws: a state naming the gripper open after the open went
    /// out. Sent alone, or refused, it keeps the object held.
    func testAnOpenLetsGoOnlyOnceTheServerOpensTheJaws() {
        var hold = held()
        hold.stateArrived(ServerState(gripper: .open))
        XCTAssertTrue(hold.holding, "no open went out")
        hold.apply(.openSent)
        XCTAssertTrue(hold.holding, "sent, not yet started")
        hold.stateArrived(ServerState(gripper: .closed))
        XCTAssertTrue(hold.holding, "a state still naming the jaws closed")
        hold.stateArrived(ServerState(gripper: .open))
        XCTAssertFalse(hold.holding, "the server opens the jaws")

        hold = held()
        hold.apply(.openSent)
        hold.apply(.openRefused)
        hold.stateArrived(ServerState(gripper: .open))
        XCTAssertTrue(hold.holding, "a refused open")
    }

    func testANewEpisodeLetsGoAndAStopDoesNot() {
        var hold = held()
        hold.stateArrived(ServerState(episode: 3))
        hold.stateArrived(ServerState(episode: 3))
        XCTAssertTrue(hold.holding, "the same episode")
        hold.stateArrived(ServerState(episode: 4))
        XCTAssertFalse(hold.holding, "a new episode is a scene reset")

        hold.apply(.contactReported)
        hold.stateArrived(ServerState(estop: true, episode: 4))
        XCTAssertTrue(hold.holding, "a stop freezes the arm; the jaws keep what they hold")
    }

    func testAReconnectForgetsTheEpisode() {
        var hold = ObjectHold()
        hold.stateArrived(ServerState(episode: 3))
        hold.apply(.reconnected)
        hold.apply(.contactReported)
        hold.stateArrived(ServerState(episode: 9))
        XCTAssertTrue(hold.holding, "the first episode heard on a new connection is no reset")
    }

    /// Not holding: the tool point with a calibration, coordinated height for up and down where the server has it.
    /// Holding: the gripper link's path for every direction.
    func testThePadPath() {
        let free = ObjectHold()
        XCTAssertEqual(
            free.padHoldPath(toolCalibrated: true, coordinatedHeight: true, vertical: true),
            PadHoldPath(useToolPoint: true, toolMotion: .coordinatedHeight))
        XCTAssertEqual(
            free.padHoldPath(toolCalibrated: true, coordinatedHeight: true, vertical: false),
            PadHoldPath(useToolPoint: true, toolMotion: nil))
        XCTAssertEqual(
            free.padHoldPath(toolCalibrated: true, coordinatedHeight: false, vertical: true),
            PadHoldPath(useToolPoint: true, toolMotion: nil))
        XCTAssertEqual(
            free.padHoldPath(toolCalibrated: false, coordinatedHeight: false, vertical: false),
            PadHoldPath(useToolPoint: false, toolMotion: nil))
        let carrying = held()
        for vertical in [false, true] {
            XCTAssertEqual(
                carrying.padHoldPath(toolCalibrated: true, coordinatedHeight: true, vertical: vertical),
                PadHoldPath(useToolPoint: false, toolMotion: nil), "vertical \(vertical)")
        }
    }
}
