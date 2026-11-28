import TeleopCore
import XCTest

@testable import Teleop

/// The scripted hand names the jaw's targets in the arm's own unit, from the profile's jaw and not from the SO-101's.
final class ScriptedHandJawTests: XCTestCase {
    func testTheHandAsksForTheJawsOwnOpenAndClosedReadings() {
        for (name, jaw) in TestProfiles.grippers {
            XCTAssertEqual(ScriptedOperator.jawTarget(.open, jaw: jaw), jaw.text(jaw.openReading), name)
            XCTAssertEqual(ScriptedOperator.jawTarget(.closed, jaw: jaw), jaw.text(jaw.closedReading), name)
        }
        XCTAssertEqual(ScriptedOperator.jawTarget(.open, jaw: TestProfiles.so101.gripper), "97 deg")
        XCTAssertEqual(ScriptedOperator.jawTarget(.closed, jaw: TestProfiles.so101.gripper), "0 deg")
        XCTAssertEqual(ScriptedOperator.jawTarget(.open, jaw: TestProfiles.benchBGripper), "40 mm")
        XCTAssertEqual(ScriptedOperator.jawTarget(.closed, jaw: TestProfiles.benchBGripper), "0 mm")
    }

    func testTheHandKeepsTheJawOfTheProfileItDrives() {
        let hand = ScriptedOperator(address: "127.0.0.1:1", smoothing: 0.3)
        XCTAssertEqual(hand.jaw, TestProfiles.so101.gripper)
    }
}
