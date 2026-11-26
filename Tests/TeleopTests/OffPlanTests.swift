import TeleopCore
import XCTest
@testable import Teleop

/// Runs only in the AssistOff test plan, which sets `TELEOP_EXPECT_ASSIST_OFF=1` beside the launch argument
/// `-assist NO`; the Default plan skips it. It shows on every run that the argument reached the hosted tests'
/// settings, so that plan really runs the app's unit tests with the master switch off.
final class OffPlanTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TELEOP_EXPECT_ASSIST_OFF"] == "1", "AssistOff plan only")
    }

    func testTheMasterSwitchIsOffInThisPlan() {
        let model = AppModel(start: .p4, liveLink: false)
        XCTAssertFalse(model.assistOn)
        XCTAssertEqual(model.assist, .off)
        XCTAssertEqual(model.controller.arbiter.assist, .off)
    }
}
