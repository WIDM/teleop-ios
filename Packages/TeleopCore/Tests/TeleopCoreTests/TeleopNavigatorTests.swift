import XCTest
@testable import TeleopCore

final class TeleopNavigatorTests: XCTestCase {
    func testNavigateIsSingleTop() {
        var nav = TeleopNavigator()
        nav.navigate(to: .t1)
        nav.navigate(to: .t1)
        XCTAssertEqual(nav.stack, [.s2, .t1])
    }

    func testBackPopsToPreviousWhenOnStack() {
        var nav = TeleopNavigator()
        for r in [Route.p4, .p5, .s1] { nav.navigate(to: r) }
        nav.back()
        XCTAssertEqual(nav.stack, [.s2, .p4, .p5])
        nav.back()
        XCTAssertEqual(nav.stack, [.s2, .p4])
    }

    func testBackPushesPreviousWhenNotOnStack() {
        var nav = TeleopNavigator(start: .s1)
        nav.back()
        XCTAssertEqual(nav.stack, [.s1, .p5])
        XCTAssertEqual(nav.current, .p5)
    }

    func testBackOnRootWithoutRuleIsNoOp() {
        var nav = TeleopNavigator()
        nav.back()
        XCTAssertEqual(nav.stack, [.s2])
    }

    func testBackWithoutRulePopsTop() {
        var nav = TeleopNavigator()
        nav.navigate(to: .p4)
        nav.back()
        XCTAssertEqual(nav.stack, [.s2])
    }
}
