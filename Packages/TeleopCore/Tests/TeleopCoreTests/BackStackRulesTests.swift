import XCTest
@testable import TeleopCore

final class BackStackRulesTests: XCTestCase {
    private func edges(_ route: Route) -> [Route] { BackStackRules.forwardEdges[route] ?? [] }

    func testP2BacksToP1() {
        XCTAssertEqual(BackStackRules.previous(of: .p2), .p1)
    }

    func testP5BacksToP4() {
        XCTAssertEqual(BackStackRules.previous(of: .p5), .p4)
    }

    func testTipCardsChainBackward() {
        XCTAssertEqual(BackStackRules.previous(of: .t1), .s2)
        XCTAssertEqual(BackStackRules.previous(of: .t2), .t1)
        XCTAssertEqual(BackStackRules.previous(of: .t3), .t2)
    }

    func testP7BacksToP5() {
        XCTAssertEqual(BackStackRules.previous(of: .p7), .p5)
    }

    func testP1HasNoBack() {
        XCTAssertNil(BackStackRules.previous(of: .p1))
        XCTAssertFalse(BackStackRules.handlesBack(.p1))
        XCTAssertTrue(BackStackRules.handlesBack(.p5))
    }

    func testSettingsAndRecordingBackToStandby() {
        XCTAssertEqual(BackStackRules.previous(of: .s6), .p4)
        XCTAssertEqual(BackStackRules.previous(of: .s3a), .p4)
    }

    func testChangeServerEdgeFromP5ToS1() {
        XCTAssertTrue(edges(.p5).contains(.s1))
    }

    func testS1BackAndChipReturnToP5() {
        XCTAssertEqual(BackStackRules.previous(of: .s1), .p5)
        XCTAssertTrue(edges(.s1).contains(.p5))
    }

    func testS1DisconnectGoesToS7AndReconnectReturns() {
        XCTAssertTrue(edges(.s1).contains(.s7))
        XCTAssertTrue(edges(.s7).contains(.s1))
        XCTAssertEqual(BackStackRules.previous(of: .s7), .s1)
    }

    func testStatusChipOnP4GoesToP5NotS1() {
        XCTAssertTrue(edges(.p4).contains(.p5))
        XCTAssertFalse(edges(.p4).contains(.s1))
    }

    func testAllTwentyRoutesReachableFromP1() {
        XCTAssertEqual(Route.allCases.count, 20)
        XCTAssertEqual(BackStackRules.reachable(from: .p1), Set(Route.allCases))
    }

    func testEveryRouteWithABackRuleHasAMatchingForwardEdgeOrIsOverride() {
        for route in Route.allCases {
            guard let previous = BackStackRules.previous(of: route) else { continue }
            XCTAssertTrue(
                BackStackRules.reachable(from: .p1).contains(previous),
                "\(route) backs to unreachable \(previous)"
            )
        }
    }
}
