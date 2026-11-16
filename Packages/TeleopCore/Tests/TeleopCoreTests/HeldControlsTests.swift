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
        XCTAssertFalse(session.state.isHolding(.wristStart))

        session.perform(.wristStart)
        XCTAssertTrue(session.state.isHolding(.wristStart))
        XCTAssertFalse(session.state.isHolding(.gripperStart(.open)))

        session.perform(.gripperStart(.open))
        XCTAssertTrue(session.state.isHolding(.gripperStart(.open)))
        XCTAssertFalse(session.state.isHolding(.gripperStart(.closed)))
        XCTAssertFalse(session.state.isHolding(.wristStart))

        session.perform(.holdArmStart)
        XCTAssertTrue(session.state.isHolding(.holdArmStart))
        XCTAssertFalse(session.state.isHolding(.gripperStart(.open)))

        session.perform(.holdArmEnd)
        session.perform(.wristStart)
        XCTAssertTrue(session.state.isHolding(.wristStart))
        XCTAssertFalse(session.state.isHolding(.holdArmStart))
        session.perform(.gripperStart(.open))
        XCTAssertFalse(session.state.isHolding(.wristStart))
    }

    func testAGripperTakenOverByTheOtherDirectionIsNotHeldByTheFirstControl() {
        var session = session()
        session.perform(.gripperStart(.open))
        session.perform(.gripperStart(.closed))
        XCTAssertFalse(session.state.isHolding(.gripperStart(.open)))
        XCTAssertTrue(session.state.isHolding(.gripperStart(.closed)))
    }

    func testActionsThatAreNotStartsAreNeverHeld() {
        var session = session()
        session.perform(.holdArmStart)
        XCTAssertFalse(session.state.isHolding(.holdArmEnd))
        XCTAssertFalse(session.state.isHolding(.stop))
    }
}
