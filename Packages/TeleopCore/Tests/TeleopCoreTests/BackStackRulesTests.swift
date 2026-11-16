import XCTest
@testable import TeleopCore

final class BackStackRulesTests: XCTestCase {
    private func edges(_ route: Route) -> [Route] { BackStackRules.forwardEdges[route] ?? [] }

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

    func testTheTwoLaunchScreensHaveNoBack() {
        XCTAssertNil(BackStackRules.previous(of: .s2))
        XCTAssertNil(BackStackRules.previous(of: .p4))
        XCTAssertFalse(BackStackRules.handlesBack(.s2))
        XCTAssertTrue(BackStackRules.handlesBack(.p5))
    }

    func testSettingsBacksToStandby() {
        XCTAssertEqual(BackStackRules.previous(of: .s6), .p4)
    }

    func testChangeServerEdgeFromP5ToS1() {
        XCTAssertTrue(edges(.p5).contains(.s1))
    }

    func testS1BackAndChipReturnToP5() {
        XCTAssertEqual(BackStackRules.previous(of: .s1), .p5)
        XCTAssertTrue(edges(.s1).contains(.p5))
    }

    func testLosingTheLinkOnAControlScreenLeadsToS1() {
        for route in BackStackRules.controlRoutes {
            XCTAssertTrue(edges(route).contains(.s1), "\(route)")
        }
    }

    func testStatusChipOnP4GoesToP5NotS1() {
        XCTAssertTrue(edges(.p4).contains(.p5))
        // P4 also has an edge to S1, for a lost link; the chip itself opens P5.
        var s = TeleopSession(start: .p4)
        s.perform(.openConnection)
        XCTAssertEqual(s.route, .p5)
    }

    func testEveryRouteReachableFromAFreshInstall() {
        XCTAssertEqual(Route.allCases.count, 11)
        XCTAssertEqual(BackStackRules.reachable(from: .s2), Set(Route.allCases))
    }

    func testEveryRouteWithABackRuleHasAMatchingForwardEdgeOrIsOverride() {
        for route in Route.allCases {
            guard let previous = BackStackRules.previous(of: route) else { continue }
            XCTAssertTrue(
                BackStackRules.reachable(from: .s2).contains(previous),
                "\(route) backs to unreachable \(previous)"
            )
        }
    }
}
