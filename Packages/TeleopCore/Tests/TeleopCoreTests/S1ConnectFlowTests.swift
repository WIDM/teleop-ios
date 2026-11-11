import XCTest
@testable import TeleopCore

/// Priority flow: status chip -> P5 -> Change server -> S1 -> Connect/Back -> P5; Disconnect stays on S1.
final class S1ConnectFlowTests: XCTestCase {
    private func standby() -> TeleopSession {
        var s = TeleopSession()
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
        XCTAssertNil(s.state.latencyMs, "the demo link measures no latency")
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

    func testS1DisconnectEndsTheLinkAndStaysOnS1() {
        var s = standby()
        s.perform(.openConnection)
        s.perform(.changeServer)
        s.perform(.disconnect)
        XCTAssertEqual(s.route, .s1)
        XCTAssertFalse(s.state.connected)
        XCTAssertFalse(s.state.connectionLost, "a chosen disconnect is not a lost connection")
        s.perform(.connect)
        XCTAssertEqual(s.route, .p5)
        XCTAssertTrue(s.state.connected)
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
        let steps: [TeleopAction] = [.openConnection, .changeServer, .connect, .changeServer, .disconnect, .s1Back]
        for action in steps {
            let from = s.route
            s.perform(action)
            // Disconnect acts in place; in-place actions are not edges.
            guard s.route != from else { continue }
            XCTAssertTrue(
                BackStackRules.forwardEdges[from, default: []].contains(s.route),
                "\(action): \(from) -> \(s.route) is not a declared edge"
            )
        }
    }
}
