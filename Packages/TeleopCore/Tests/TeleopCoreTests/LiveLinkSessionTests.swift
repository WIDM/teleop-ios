import XCTest
@testable import TeleopCore

final class LiveLinkSessionTests: XCTestCase {
    private func live(at route: Route = .p1) -> TeleopSession {
        var state = FakeTeleopState()
        state.liveLink = true
        return TeleopSession(state: state, start: route)
    }

    func testReachingStandbyDoesNotPretendToBeConnected() {
        var s = live()
        s.perform(.modeNext)
        s.perform(.permissionsContinue)
        s.perform(.tutorialSkip)
        XCTAssertEqual(s.route, .p4)
        XCTAssertFalse(s.state.connected)
        s.perform(.holdArmStart)
        XCTAssertFalse(s.state.armMoving)
    }

    func testCloudCheckDoesNotPretendToBeConnected() {
        var s = live()
        s.state.selectCloud()
        s.perform(.modeNext)
        XCTAssertFalse(s.state.connected)
        s.perform(.cloudUseOnSite)
        XCTAssertFalse(s.state.connected)
    }

    func testConnectButtonAloneDoesNothing() {
        var s = live(at: .s1)
        s.perform(.connect)
        XCTAssertEqual(s.route, .s1)
        XCTAssertFalse(s.state.connected)
    }

    func testLinkUpConnectsAndLeavesTheConnectScreen() {
        var s = live(at: .s1)
        s.state.serverInputError = true
        s.perform(.linkUp(gripper: .closed))
        XCTAssertTrue(s.state.connected)
        XCTAssertTrue(s.state.heartbeatOk)
        XCTAssertFalse(s.state.serverInputError)
        XCTAssertEqual(s.state.gripper, .closed)
        XCTAssertEqual(s.route, .p5)
    }

    func testLinkUpElsewhereDoesNotNavigate() {
        var s = live(at: .p4)
        s.perform(.linkUp(gripper: nil))
        XCTAssertEqual(s.route, .p4)
        XCTAssertEqual(s.state.gripper, .open)
    }

    func testLinkLostStopsTheArmAndOpensErrors() {
        var s = live(at: .p4)
        s.perform(.linkUp(gripper: nil))
        s.perform(.holdArmStart)
        s.perform(.linkLost)
        XCTAssertFalse(s.state.connected)
        XCTAssertFalse(s.state.armMoving)
        XCTAssertEqual(s.route, .s7)
    }

    func testLinkLostWhileEStoppedKeepsS4() {
        var s = live(at: .p4)
        s.perform(.linkUp(gripper: nil))
        s.perform(.stop)
        s.perform(.linkLost)
        XCTAssertEqual(s.route, .s4)
        XCTAssertTrue(s.state.emergencyStop)
    }

    func testLinkLostOnSettingsStaysThere() {
        var s = live(at: .s6)
        s.perform(.linkUp(gripper: nil))
        s.perform(.linkLost)
        XCTAssertEqual(s.route, .s6)
        XCTAssertFalse(s.state.connected)
    }

    func testFailedAttemptShowsTheErrorOnTheConnectScreen() {
        var s = live(at: .s1)
        s.perform(.linkLost)
        XCTAssertEqual(s.route, .s1)
        XCTAssertTrue(s.state.serverInputError)
    }

    func testSlowLinkBlocksStopsTheArmAndShowsP6() {
        var s = live(at: .p4)
        s.perform(.linkUp(gripper: nil))
        s.perform(.holdArmStart)
        s.perform(.linkLatency(ms: 900))
        XCTAssertFalse(s.state.commandsBlocked, "one slow sample must not block")
        XCTAssertTrue(s.state.armMoving)
        XCTAssertEqual(s.state.latencyMs, 900)
        s.perform(.linkLatency(ms: FakeTeleopState.blockLatencyMs))
        XCTAssertTrue(s.state.commandsBlocked)
        XCTAssertFalse(s.state.armMoving)
        XCTAssertEqual(s.route, .p6)
        s.perform(.linkLatency(ms: 60))
        XCTAssertFalse(s.state.commandsBlocked)
        XCTAssertEqual(s.state.latencyMs, 60)
        XCTAssertEqual(s.route, .p4)
    }

    func testOneSlowSampleBetweenFastOnesNeverBlocks() {
        var s = live(at: .p4)
        s.perform(.linkUp(gripper: nil))
        for ms in [30, 2000, 40, 1500, 20] { s.perform(.linkLatency(ms: ms)) }
        XCTAssertFalse(s.state.commandsBlocked)
        XCTAssertEqual(s.route, .p4)
    }

    func testLatencyWhileDisconnectedIsIgnored() {
        var s = live(at: .p4)
        s.perform(.linkLatency(ms: 900))
        XCTAssertFalse(s.state.commandsBlocked)
    }

    func testLinkEventsAreIgnoredOnTheFakeLink() {
        var s = TeleopSession(start: .p4)
        s.perform(.linkUp(gripper: .closed))
        XCTAssertFalse(s.state.connected)
        s.state.markConnected()
        s.perform(.linkLost)
        XCTAssertTrue(s.state.connected)
        s.perform(.linkLatency(ms: 900))
        XCTAssertFalse(s.state.commandsBlocked)
    }
}
