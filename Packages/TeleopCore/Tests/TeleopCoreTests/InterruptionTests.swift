import XCTest
@testable import TeleopCore

/// Every hold now ends with a reason. For a hold tied to an input and for the reset countdown the reason changes
/// nothing: each one ends them exactly as the reasonless event did, and leaves every input in the same state.
final class InterruptionTests: XCTestCase {
    typealias Rig = ArbiterRig

    static let reasons: [Interruption] = [
        .unnamed, .announced, .startRefused, .appLeft, .cameraStopped, .leftScreen, .slowLink,
    ]

    private struct Situation {
        var name: String
        var scheme: InputScheme
        var engaged: Engagement?
        var setUp: (inout Rig) -> Void
    }

    private let situations: [Situation] = [
        Situation(name: "the upper key's hold", scheme: .screenTurns, engaged: .held(.key(.upper), .translation)) {
            $0.press(.upper)
            $0.touchDown(1, at: Rig.middle)
        },
        Situation(name: "a wrist hold on the lower key", scheme: .keyTurns, engaged: .held(.key(.lower), .wrist)) {
            $0.press(.lower)
            $0.rotate(turn: 15)
        },
        Situation(name: "a thumb holding a half", scheme: .keyTurns, engaged: .held(.touch(1), .gripper(.closed))) {
            $0.touchDown(1, at: Rig.rightHalf)
            $0.wait(0.2)
        },
        Situation(name: "the reset countdown", scheme: .keyTurns, engaged: .countdown(touch: 1)) {
            $0.touchDown(1, at: Rig.topBand)
            $0.wait(0.5)
        },
        Situation(name: "nothing engaged, a thumb undecided", scheme: .screenTurns, engaged: nil) {
            $0.touchDown(1, at: Rig.middle)
        },
    ]

    func testEveryReasonIsEndAllHoldsForAHeldHold() {
        for situation in situations {
            var reference = Rig(situation.scheme)
            situation.setUp(&reference)
            XCTAssertEqual(reference.arbiter.engagement, situation.engaged, situation.name)
            let expected = reference.send(.endAllHolds, after: 0.2)
            let expectedHeld = reference.arbiter.held
            let expectedAfter = Self.afterwards(&reference)
            for reason in Self.reasons {
                var rig = Rig(situation.scheme)
                situation.setUp(&rig)
                XCTAssertEqual(rig.send(.holdsEnded(reason), after: 0.2), expected, "\(situation.name), \(reason)")
                XCTAssertNil(rig.arbiter.engagement, "\(situation.name), \(reason)")
                XCTAssertEqual(rig.arbiter.held, expectedHeld, "\(situation.name), \(reason)")
                XCTAssertEqual(Self.afterwards(&rig), expectedAfter, "\(situation.name), \(reason)")
            }
        }
    }

    func testTheShorthandIsUnnamed() {
        XCTAssertEqual(InputEvent.endAllHolds, .holdsEnded(.unnamed))
    }

    /// Everything let go of, then a fresh press and release: what the inputs held across the ending still do.
    private static func afterwards(_ rig: inout Rig) -> [InputCommand] {
        rig.wait(3) + rig.release(.upper) + rig.release(.lower) + rig.lift(1) + rig.press(.upper, after: 1)
            + rig.release(.upper, after: 0.2)
    }
}
