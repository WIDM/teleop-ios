import XCTest
@testable import TeleopCore

/// Priority flow: status chip -> P5 -> Change server -> S1 -> Connect/Back -> P5, Disconnect -> S7 -> Reconnect -> S1.
final class S1ConnectFlowTests: XCTestCase {
    private func standby() -> TeleopSession {
        var s = TeleopSession()
        s.perform(.modeNext)
        s.perform(.permissionsContinue)
        s.perform(.tutorialSkip)
        XCTAssertEqual(s.route, .p4)
        return s
    }

    func testStatusChipOpensP5() {
        var s = standby()
        s.perform(.openConnection)
        XCTAssertEqual(s.route, .p5)
    }

    func testP5ChangeServerOpensS1() {
        var s = standby()
        s.perform(.openConnection)
        s.perform(.changeServer)
        XCTAssertEqual(s.route, .s1)
    }

    func testS1ConnectReturnsToP5AndMarksConnected() {
        var s = standby()
        s.perform(.openConnection)
        s.perform(.changeServer)
        s.state.connected = false
        s.perform(.connect)
        XCTAssertEqual(s.route, .p5)
        XCTAssertTrue(s.state.connected)
        XCTAssertEqual(s.state.latencyMs, 80)
    }

    func testS1BackReturnsToP5() {
        var s = standby()
        s.perform(.openConnection)
        s.perform(.changeServer)
        s.perform(.s1Back)
        XCTAssertEqual(s.route, .p5)
    }

    func testS1SystemBackReturnsToP5() {
        var s = standby()
        s.perform(.openConnection)
        s.perform(.changeServer)
        s.perform(.back)
        XCTAssertEqual(s.route, .p5)
    }

    func testS1ChipReturnsToP5() {
        var s = standby()
        s.perform(.openConnection)
        s.perform(.changeServer)
        s.perform(.openConnection)
        XCTAssertEqual(s.route, .p5)
    }

    func testS1DisconnectGoesToS7AndReconnectReturnsToS1() {
        var s = standby()
        s.perform(.openConnection)
        s.perform(.changeServer)
        s.perform(.disconnect)
        XCTAssertEqual(s.route, .s7)
        XCTAssertFalse(s.state.connected)
        XCTAssertFalse(s.state.heartbeatOk)
        s.perform(.reconnect)
        XCTAssertEqual(s.route, .s1)
    }

    func testS7BackToConnectReturnsToS1() {
        var s = standby()
        s.perform(.openConnection)
        s.perform(.changeServer)
        s.perform(.disconnect)
        s.perform(.backToConnect)
        XCTAssertEqual(s.route, .s1)
    }

    func testFullLoopThenSystemBackWalksToStandby() {
        var s = standby()
        s.perform(.openConnection)
        s.perform(.changeServer)
        s.perform(.connect)
        s.perform(.back)
        XCTAssertEqual(s.route, .p4)
    }

    func testEveryPerformedTransitionIsADeclaredForwardEdge() {
        var s = standby()
        let steps: [TeleopAction] = [.openConnection, .changeServer, .connect, .changeServer, .disconnect, .reconnect, .s1Back]
        for action in steps {
            let from = s.route
            s.perform(action)
            XCTAssertTrue(
                BackStackRules.forwardEdges[from, default: []].contains(s.route),
                "\(action): \(from) -> \(s.route) is not a declared edge"
            )
        }
    }
}
