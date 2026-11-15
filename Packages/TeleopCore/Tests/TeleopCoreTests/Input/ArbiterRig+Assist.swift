import simd
import XCTest
@testable import TeleopCore

extension ArbiterRig {
    /// A rig whose arbiter has these aids. With `.off` it is exactly `ArbiterRig(scheme)`.
    init(_ scheme: InputScheme, hand: Hand = .right, assist: Assist) {
        self.init(scheme, hand: hand)
        arbiter = InputArbiter(scheme: scheme, hand: hand, layout: Self.layout, assist: assist)
        send(.attitude(Phone.rest))
    }

    /// Lock, variant 1, with the SO-101's 30 s limit unless another is given.
    static func lockPressPress(limit: Double = 30) -> Assist {
        Assist(lock: LockRule(variant: .pressPress, timeLimitS: limit))
    }

    /// Variant 1: a press of the upper key latches; it is released at once.
    @discardableResult
    mutating func latchByPress(after dt: TimeInterval = 0) -> [InputCommand] {
        press(.upper, after: dt) + release(.upper)
    }

    /// The drive cues among `commands`.
    static func drives(_ commands: [InputCommand]) -> [DriveCue] {
        commands.cues.compactMap { if case .drive(let cue) = $0 { return cue } else { return nil } }
    }

    var isLatched: Bool {
        if case .latched? = arbiter.engagement { return true }
        return false
    }
}
