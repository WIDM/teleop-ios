import simd
import XCTest
@testable import TeleopCore

/// A move to a tapped point, once it goes: it ends on measured positions (arrived, stopped short after its
/// corrections, no arm data) or at its deadline, never on the phone, and streams its offset on the rules' own clock.
final class GoingTests: XCTestCase {
    typealias Rig = ArbiterRig

    /// The gate runs at the owner's tick.
    private let step = 1.0 / 30
    /// The arm at the box's centre, at the travel height.
    private let start = SIMD3(0.027617, -0.177418, Rig.travelZ)
    /// Inside the panel on a half in both schemes; it sends the arm 5.2 cm across, level.
    private let point = Rig.inPanel(0.3, 0.65)
    private var target: SIMD3<Double> { Rig.target(of: point) }

    /// A rig whose tap at `point` started a move from `from`, the arm measured there.
    private func going(
        _ scheme: InputScheme = .screenTurns, from: SIMD3<Double>? = nil, limits: GoToLimits = Rig.goLimits,
        file: StaticString = #filePath, line: UInt = #line
    ) -> Rig {
        var rig = Rig(scheme, assist: Rig.goTo(limits))
        rig.facts = Rig.goFacts(arm: from ?? start)
        XCTAssertEqual(rig.tap(1, at: point, after: 0.1), [.startTranslation], file: file, line: line)
        XCTAssertTrue(rig.isGoing, file: file, line: line)
        return rig
    }

    /// Ticks `rig` at the gate's rate for up to `seconds`. Before each call the arm is measured `age` before it, at
    /// what `arm` makes of the point the move commanded `lag` before that and of the time since the move began.
    /// Returns what the call that ended the move gave, and when; nil if it still goes.
    private func drive(
        _ rig: inout Rig, from start: SIMD3<Double>, seconds: Double, age: Double = 0.1, lag: Double = 0.1,
        arm: (SIMD3<Double>, TimeInterval) -> SIMD3<Double> = { commanded, _ in commanded }
    ) -> (commands: [InputCommand], at: TimeInterval)? {
        let began = rig.time
        var history: [(at: TimeInterval, point: SIMD3<Double>)] = [(began, rig.commanded(from: start) ?? start)]
        while rig.time < began + seconds - 1e-9 {
            let measured = rig.time + step - age
            let commanded = history.last { $0.at <= measured - lag }?.point ?? start
            rig.facts.arm = ArmFix(pinch: arm(commanded, measured - began), ageS: age, holdPaused: false)
            let commands = rig.wait(step)
            guard rig.isGoing else { return (commands, rig.time) }
            history.append((rig.time, rig.commanded(from: start)!))
        }
        return nil
    }

    private func ended(_ end: DriveEnd) -> [InputCommand] { [.stopTranslation, .cue(.drive(.ended(end)))] }

    /// The command reaching the target ends nothing; a stale position there ends nothing; a fresh one within 8 mm
    /// does, with "Arrived.".
    func testItArrivesOnAFreshFixNotOnTheCommand() {
        var rig = going()
        XCTAssertNil(drive(&rig, from: start, seconds: 1.4) { _, _ in self.start }, "the arm still where it began")
        let commanded = rig.commanded(from: start)!
        XCTAssertEqual(simd_distance(commanded, target), 0, accuracy: 1e-12, "the command is at the target")

        rig.facts.arm = ArmFix(pinch: target, ageS: 0.5, holdPaused: false)
        XCTAssertEqual(rig.wait(step), [], "a position 0.5 s old says nothing")
        rig.facts.arm = ArmFix(pinch: target + SIMD3(0.005, 0, -0.005), ageS: 0.1, holdPaused: false)
        XCTAssertEqual(rig.wait(step), [.stopTranslation, .cue(.drive(.arrived))])
        XCTAssertNil(rig.arbiter.engagement)
        XCTAssertNil(rig.arbiter.goOffset(at: rig.time))
        XCTAssertNil(rig.arbiter.nextDeadline)

        var following = going(.keyTurns)
        let end = drive(&following, from: start, seconds: 4)
        XCTAssertEqual(end?.commands, [.stopTranslation, .cue(.drive(.arrived))], "an arm that follows arrives")
    }

    /// An arm held 2 cm short by something in its way: the move aims again by what is missing, twice, then stops
    /// short. The target lies between 2 and 4 cm inside a face of the work box, so the second aim stops at that face.
    func testItStopsShortAfterItsCorrections() {
        var rig = going()
        let wall = target.x - 0.02
        var farthestCommanded = -Double.infinity
        let end = drive(&rig, from: start, seconds: 8) { commanded, _ in
            farthestCommanded = max(farthestCommanded, commanded.x)
            return SIMD3(min(commanded.x, wall), commanded.y, commanded.z)
        }
        XCTAssertEqual(end?.commands, ended(.stoppedShort))
        XCTAssertGreaterThan(Rig.boxHigh.x, target.x + 0.02, "the first aim ends inside the box")
        XCTAssertLessThan(Rig.boxHigh.x, target.x + 0.04, "the second would end past its face")
        // The first correction moved the end by the 2 cm still missing; the second, which would have moved it 2 cm
        // more, ended on the box's face. Then the budget was spent.
        XCTAssertEqual(farthestCommanded, Rig.boxHigh.x, accuracy: 1e-9)
    }

    /// The arm standing still for 1.4 s after the tap, the command long at the corner: no stall is judged before the
    /// start's grace is over, and once the arm moves the move goes on and arrives.
    func testASlowStartIsNotTakenForAStall() {
        let low = start - SIMD3(0, 0, 0.009)
        var rig = going(from: low)
        let end = drive(&rig, from: low, seconds: 6) { commanded, since in since < 1.4 ? low : commanded }
        XCTAssertEqual(end?.commands, [.stopTranslation, .cue(.drive(.arrived))])
    }

    /// No position younger than 2 s ends the move with "No arm data.", and so does no position at all.
    func testItEndsWithNoArmData() {
        var rig = going()
        rig.facts.arm = ArmFix(pinch: start, ageS: 1.9, holdPaused: false)
        XCTAssertEqual(rig.wait(step), [], "1.9 s old")
        rig.facts.arm = ArmFix(pinch: start, ageS: 2.05, holdPaused: false)
        XCTAssertEqual(rig.wait(step), ended(.noArmData))
        XCTAssertNil(rig.arbiter.engagement)

        var none = going()
        none.facts.arm = nil
        XCTAssertEqual(none.wait(step), ended(.noArmData))
    }

    /// An arm that keeps creeping, never still and never there: "Time is up." in the first call at or after the
    /// deadline, path over speed times 1.5 plus 3 s, which is the next thing to tick for.
    func testItEndsOnItsDeadline() {
        var rig = going()
        let since = rig.time
        let path = abs(target.z - start.z) + simd_length(SIMD2(target.x - start.x, target.y - start.y))
        let limits = Rig.goLimits
        let deadline = since + path / limits.speedMps * limits.timeFactor + limits.allowanceS
        XCTAssertEqual(rig.arbiter.nextDeadline, deadline)
        var creep = start
        let end = drive(&rig, from: start, seconds: 8) { commanded, _ in
            let gap = commanded - creep
            let reach = 0.008 * self.step
            creep += simd_length(gap) > reach ? simd_normalize(gap) * reach : gap
            return creep
        }
        XCTAssertEqual(end?.commands, ended(.timeLimit))
        XCTAssertGreaterThanOrEqual(end?.at ?? 0, deadline - 1e-9)
        XCTAssertLessThan(end?.at ?? .infinity, deadline + step)
    }

    /// The phone does not steer the move, so neither lost tracking, nor a phone tipped over, nor its turns end it.
    func testThePhoneDoesNotEndIt() {
        var rig = going()
        rig.facts.trackingRefusal = .notTracking
        rig.facts.translationRefusal = .posture
        XCTAssertEqual(rig.wait(step), [])
        XCTAssertEqual(rig.rotate(turn: 40, tilt: 25), [])
        XCTAssertEqual(rig.wait(0.3), [])
        XCTAssertTrue(rig.isGoing)
    }

    /// The offset is asked for on the rules' clock: a time before the newest call is that call's, and a later one runs
    /// on along the leg at the profile's speed, in the frame the link sends (up the arm is down in that frame).
    func testGoOffsetIsOnTheArbitersClock() {
        let idle = Rig(.screenTurns, assist: Rig.goTo())
        XCTAssertNil(idle.arbiter.goOffset(at: idle.time), "nothing goes")

        var rig = going(from: start - SIMD3(0, 0, 0.02))
        let now = rig.time
        XCTAssertEqual(rig.arbiter.goOffset(at: now - 1), rig.arbiter.goOffset(at: now))
        XCTAssertEqual(rig.arbiter.goOffset(at: now), .zero)
        let later = rig.arbiter.goOffset(at: now + 0.25)!
        XCTAssertEqual(later.x, 0, accuracy: 1e-12)
        XCTAssertEqual(later.y, 0, accuracy: 1e-12)
        XCTAssertEqual(later.z, -0.01, accuracy: 1e-12, "1 cm up the first leg after 0.25 s, sign flipped")
        rig.press(.upper, after: 0.1)
        XCTAssertNil(rig.arbiter.goOffset(at: rig.time), "nothing goes once it ended")
    }

    /// Carrying something in the jaws is no reason not to go.
    func testItWorksWhileGripping() {
        var rig = Rig(.keyTurns, assist: Rig.goTo())
        rig.facts = Rig.goFacts(arm: start)
        rig.facts.gripping = true
        XCTAssertEqual(rig.tap(1, at: point, after: 0.1), [.startTranslation])
        XCTAssertEqual(drive(&rig, from: start, seconds: 4)?.commands, [.stopTranslation, .cue(.drive(.arrived))])
    }
}
