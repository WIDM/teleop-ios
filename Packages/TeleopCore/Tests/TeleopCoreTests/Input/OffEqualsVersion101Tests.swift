import XCTest
@testable import TeleopCore

/// Today's input rules, as every caller builds them, against version 1.0.1's, frozen in this test target as
/// `InputArbiter101`. Both are fed the same 12,000 generated cases (the property test's generator and seed) and must
/// agree at every step on the commands and on what each input is doing, and on what they report about engagement and
/// timers. Nothing is listed by hand, so whatever is added later is held to 1.0.1 here.
final class OffEqualsVersion101Tests: XCTestCase {
    func testTheArbiterWithTheAidsOffIsVersion101() {
        var rng = SplitMix64(seed: 0x7E1E_0B5)
        for index in 0..<InputArbiterPropertyTests.cases {
            let scenario = Scenario.generate(&rng, index: index)
            var old = InputArbiter101(scheme: scenario.scheme, hand: scenario.hand, layout: ArbiterRig.layout)
            var new = InputArbiter(scheme: scenario.scheme, hand: scenario.hand, layout: ArbiterRig.layout)
            for step in scenario.timeline {
                let facts = scenario.facts(at: step.time)
                let expected = old.handle(step.event, at: step.time, facts: facts)
                let got = new.handle(step.event, at: step.time, facts: facts)
                func fail(_ what: String) {
                    XCTFail("case \(index) (\(scenario.summary)) at \(step.time), \(step.event): \(what)")
                }
                guard got == expected else { return fail("\(got), 1.0.1 \(expected)") }
                guard new.held == old.held else { return fail("held \(new.held), 1.0.1 \(old.held)") }
                guard new.engagedHold == old.engagedHold, new.nextDeadline == old.nextDeadline,
                    new.countdownTouchID == old.countdownTouchID, new.isHoldingAnInput == old.isHoldingAnInput
                else { return fail("the state it reports differs from 1.0.1") }
            }
        }
    }
}
