import XCTest
@testable import TeleopCore

final class HeldControlsTests: XCTestCase {
    private func session() -> TeleopSession {
        var session = TeleopSession(start: .p4)
        session.state.markConnected()
        return session
    }

    func testOnlyTheRunningHoldIsHeld() {
        var session = session()
        XCTAssertFalse(session.state.isHolding(.holdArmStart))
        XCTAssertFalse(session.state.isHolding(.gripperStart(.open)))
        XCTAssertFalse(session.state.isHolding(.turnStart(.positive)))

        session.perform(.turnStart(.positive))
        XCTAssertTrue(session.state.isHolding(.turnStart(.positive)))
        XCTAssertFalse(session.state.isHolding(.turnStart(.negative)))
        XCTAssertFalse(session.state.isHolding(.gripperStart(.open)))

        session.perform(.gripperStart(.open))
        XCTAssertTrue(session.state.isHolding(.gripperStart(.open)))
        XCTAssertFalse(session.state.isHolding(.gripperStart(.closed)))
        XCTAssertFalse(session.state.isHolding(.turnStart(.positive)))

        session.perform(.holdArmStart)
        XCTAssertTrue(session.state.isHolding(.holdArmStart))
        XCTAssertFalse(session.state.isHolding(.gripperStart(.open)))
    }

    func testATurnTakenOverByTheOtherDirectionIsNotHeldByTheFirstControl() {
        var session = session()
        session.perform(.turnStart(.positive))
        session.perform(.turnStart(.negative))
        XCTAssertFalse(session.state.isHolding(.turnStart(.positive)))
        XCTAssertTrue(session.state.isHolding(.turnStart(.negative)))
    }

    func testATiltIsHeldOnlyByItsOwnDirection() {
        var session = session()
        session.perform(.turnStart(.tiltDown))
        XCTAssertTrue(session.state.isHolding(.turnStart(.tiltDown)))
        XCTAssertFalse(session.state.isHolding(.turnStart(.tiltUp)))
        XCTAssertFalse(session.state.isHolding(.turnStart(.positive)))
        session.perform(.turnStart(.tiltUp))
        XCTAssertFalse(session.state.isHolding(.turnStart(.tiltDown)))
        XCTAssertTrue(session.state.isHolding(.turnStart(.tiltUp)))
    }

    func testActionsThatAreNotStartsAreNeverHeld() {
        var session = session()
        session.perform(.holdArmStart)
        XCTAssertFalse(session.state.isHolding(.holdArmEnd))
        XCTAssertFalse(session.state.isHolding(.stop))
    }
}
