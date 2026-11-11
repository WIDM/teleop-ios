import XCTest
@testable import TeleopCore

final class OperatorFrameTests: XCTestCase {
    /// INTERACTION §3.3, copied by hand: button, base axis, sign.
    func testTheAxisTableIsTheSpecification() {
        let table: [(OperatorDirection, BaseAxis, Double)] = [
            (.forward, .y, -1),
            (.back, .y, +1),
            (.left, .x, +1),
            (.right, .x, -1),
            (.up, .z, +1),
            (.down, .z, -1),
        ]
        XCTAssertEqual(table.count, OperatorDirection.allCases.count)
        for (direction, axis, sign) in table {
            XCTAssertEqual(direction.baseAxis.axis, axis, "\(direction)")
            XCTAssertEqual(direction.baseAxis.sign, sign, "\(direction)")
        }
    }

    func testEveryDirectionIsOneUnitAlongItsAxis() {
        for direction in OperatorDirection.allCases {
            let v = direction.baseVector
            XCTAssertEqual(abs(v.x) + abs(v.y) + abs(v.z), 1, "\(direction)")
        }
    }

    func testOppositeDirectionsCancel() {
        let pairs: [(OperatorDirection, OperatorDirection)] = [(.forward, .back), (.left, .right), (.up, .down)]
        for (a, b) in pairs {
            XCTAssertEqual(a.linkVector + b.linkVector, .zero, "\(a) and \(b)")
        }
    }

    /// The server moves the base by [p0, p1, −p2]; what the link is sent must come back as the table's direction.
    func testTheLinkFrameMapsBackToTheTable() {
        for direction in OperatorDirection.allCases {
            XCTAssertEqual(OperatorFrame.base(fromLink: direction.linkVector), direction.baseVector, "\(direction)")
        }
        XCTAssertEqual(OperatorDirection.up.linkVector, SIMD3(0, 0, -1), "up goes out as −z")
        XCTAssertEqual(OperatorDirection.forward.linkVector, SIMD3(0, -1, 0), "forward goes out as −y")
        XCTAssertEqual(OperatorDirection.right.linkVector, SIMD3(-1, 0, 0), "right goes out as −x")
    }

    /// The phone's mapping (LiveLinkController.serverOffset) sends right, forward and up each negated. The same
    /// offset must come out of the shared mapping, so a button and the phone move the arm the same way.
    func testOperatorOffsetMatchesThePhoneMapping() {
        let offset = OperatorFrame.linkOffset(right: 0.01, forward: 0.02, up: 0.03)
        XCTAssertEqual(offset, SIMD3(-0.01, -0.02, -0.03))
        XCTAssertEqual(OperatorFrame.linkOffset(right: -1, forward: 0, up: 0), OperatorDirection.left.linkVector)
        XCTAssertEqual(OperatorFrame.linkOffset(right: 0, forward: -1, up: 0), OperatorDirection.back.linkVector)
        XCTAssertEqual(OperatorFrame.linkOffset(right: 0, forward: 0, up: -1), OperatorDirection.down.linkVector)
    }
}
