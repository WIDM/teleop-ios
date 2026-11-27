import TeleopCore
import XCTest

@testable import Teleop

/// The scripted hand turns where the arm has to go into the phone's move and into button presses through the arm's
/// frames, not through the SO-101's axes.
final class ScriptedHandFramesTests: XCTestCase {
    /// Where the hand goes for each direction (right, up, back; an upright phone: right +x, up +y, forward −z).
    private let hand: [OperatorDirection: SIMD3<Float>] = [
        .right: SIMD3(1, 0, 0), .left: SIMD3(-1, 0, 0), .up: SIMD3(0, 1, 0), .down: SIMD3(0, -1, 0),
        .forward: SIMD3(0, 0, -1), .back: SIMD3(0, 0, 1),
    ]

    func testAMoveAlongEachBaseAxisIsTheHandMoveOfItsDirection() {
        for (name, frames) in TestFrames.all {
            for direction in OperatorDirection.allCases {
                let remaining = SIMD3<Float>(frames.baseVector(direction)) * 0.05
                XCTAssertEqual(
                    ScriptedOperator.handOffset(for: remaining, frames: frames), hand[direction]! * 0.05,
                    "\(name) \(direction)")
            }
        }
    }

    func testAMoveAlongEachBaseAxisPressesTheButtonOfItsDirection() {
        for (name, frames) in TestFrames.all {
            for direction in OperatorDirection.allCases {
                let remaining = SIMD3<Float>(frames.baseVector(direction)) * 0.05
                let pressed = ScriptedOperator.buttonParts(for: remaining, frames: frames).filter { $0.1 >= 0.001 }
                XCTAssertEqual(pressed.map(\.0), [direction.buttonID], "\(name) \(direction)")
                XCTAssertEqual(pressed.first?.1 ?? 0, 0.05, accuracy: 1e-6, "\(name) \(direction)")
            }
        }
    }
}

extension OperatorDirection {
    fileprivate var buttonID: ButtonID {
        switch self {
        case .forward: return .forward
        case .back: return .back
        case .left: return .left
        case .right: return .right
        case .up: return .up
        case .down: return .down
        }
    }
}
