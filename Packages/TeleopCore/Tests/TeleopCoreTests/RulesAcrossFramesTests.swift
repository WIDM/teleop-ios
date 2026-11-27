import XCTest
import simd

@testable import TeleopCore

/// Every rule that takes the profile's frames, run through the SO-101's frames and through bench arm B's. What B must
/// do is what the SO-101 does, carried through the frames (`TestFrames.carry`): the same moves of the same arm seen
/// by the same operator. No expected value of B is typed here. The SO-101's own results are pinned by each rule's own
/// tests; these show that nothing in a rule depends on which axis is which.
class RulesAcrossFramesTests: XCTestCase {
    private let so = TestFrames.so101
    /// The frames run against the SO-101's; the subclass below runs the same tests with an arm on its side.
    var b: Frames { TestFrames.benchB }

    private func carry(_ p: SIMD3<Double>) -> SIMD3<Double> { TestFrames.carry(p, from: so, to: b) }

    private func assertEqual(
        _ a: SIMD3<Double>, _ expected: SIMD3<Double>, _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            simd_distance(a, expected), 0, accuracy: 1e-12, "\(a) is not \(expected) \(message())", file: file,
            line: line)
    }

    // MARK: Buttons

    func testEveryButtonRampGoesOutAsTheSO101DoesCarriedThroughTheLink() {
        for direction in OperatorDirection.allCases {
            for speed in ButtonSpeed.allCases {
                let first = ButtonRamp(direction: direction, speed: speed, startMs: 100, frames: so)
                let second = ButtonRamp(direction: direction, speed: speed, startMs: 100, frames: b)
                for ms in [100, 600, 1_100, 4_100] {
                    assertEqual(
                        second.offset(atMs: ms), TestFrames.carryLink(first.offset(atMs: ms), from: so, to: b),
                        "\(direction) \(speed) at \(ms)")
                }
            }
        }
    }

    /// A button moves the arm along the base axis its direction names: the offset the link is sent, taken back to the
    /// base frame, is that axis.
    func testEveryButtonMovesTheArmAlongItsBaseAxis() {
        for (name, frames) in TestFrames.all {
            for direction in OperatorDirection.allCases {
                let ramp = ButtonRamp(direction: direction, speed: .coarse, startMs: 0, frames: frames)
                assertEqual(
                    frames.base(fromLink: ramp.offset(atMs: 1_000)), frames.axis(for: direction).vector * 0.04,
                    "\(name) \(direction)")
            }
        }
    }

    func testAPadSittingGoesOutAsTheSO101DoesCarried() {
        func sitting(_ frames: Frames) -> [ButtonCommand] {
            var pad = ButtonArbiter(frames: frames)
            var out: [ButtonCommand] = []
            for (i, button) in [ButtonID.forward, .left, .up, .down].enumerated() {
                let t = i * 3_000
                out += pad.press(button, atMs: t, gripping: false)
                out += pad.tick(atMs: t + 500)
                out += pad.tick(atMs: t + 1_500)
                pad.rampBlocked(atMs: t + 2_000)
                out += pad.tick(atMs: t + 2_500)
                out += pad.release(button)
            }
            return out
        }
        let first = sitting(so), second = sitting(b)
        XCTAssertEqual(first.count, second.count)
        XCTAssertGreaterThan(first.count, 12)
        for (x, y) in zip(first, second) {
            if case .updateTranslation(let offset) = x {
                guard case .updateTranslation(let other) = y else { return XCTFail("\(x) against \(y)") }
                assertEqual(other, TestFrames.carryLink(offset, from: so, to: b))
            } else {
                XCTAssertEqual(x, y)
            }
        }
    }

    // MARK: Voice

    func testAVoiceAxisProjectsAsTheSO101DoesCarriedThroughTheLink() {
        for axis in TranslationAxis.allCases {
            let first = axis.project(right: 3, forward: 2, up: -5, frames: so)
            let second = axis.project(right: 3, forward: 2, up: -5, frames: b)
            assertEqual(second, TestFrames.carryLink(first, from: so, to: b), "\(axis)")
        }
    }

    // MARK: The guide's projection and the panel

    private let boxLow = SIMD3(-0.052383, -0.257418, -0.008015)
    private let boxHigh = SIMD3(0.107617, -0.097418, 0.151985)

    private func projection(_ frames: Frames) -> GuideProjection {
        let box = TestFrames.carry((boxLow, boxHigh), from: so, to: frames)
        let a = frames.operatorPoint(box.low), c = frames.operatorPoint(box.high)
        return GuideProjection(frames: frames, boxLow: simd_min(a, c), boxHigh: simd_max(a, c), table: 0.04)
    }

    /// The views span the same operator-frame ranges whichever way the base is turned, and a place is drawn at the same
    /// spot: what is drawn depends on the operator's view only.
    func testTheGuideDrawsTheSameSpotsForBothArms() {
        let first = projection(so), second = projection(b)
        XCTAssertEqual(first.across, second.across)
        XCTAssertEqual(first.depth, second.depth)
        XCTAssertEqual(first.height, second.height)
        var random = SplitMix64(seed: 11)
        for _ in 0..<100 {
            let p = SIMD3(random.uniform(-0.1, 0.15), random.uniform(-0.3, -0.05), random.uniform(0, 0.2))
            XCTAssertEqual(first.above(first.operatorPoint(p)), second.above(second.operatorPoint(carry(p))))
            XCTAssertEqual(first.behind(first.operatorPoint(p)), second.behind(second.operatorPoint(carry(p))))
            let share = SIMD2(random.uniform(0, 1), random.uniform(0, 1))
            assertEqual(
                second.base(fromOperator: second.point(aboveShare: share, up: 0.09)),
                carry(first.base(fromOperator: first.point(aboveShare: share, up: 0.09))))
            assertEqual(
                second.base(fromOperator: second.point(behindShare: share, forward: -0.1)),
                carry(first.base(fromOperator: first.point(behindShare: share, forward: -0.1))))
        }
    }

    private func panel(_ frames: Frames) -> GoPanel {
        let box = TestFrames.carry((boxLow, boxHigh), from: so, to: frames)
        return GoPanel(
            rect: SurfaceLayout.Rect(x: 118, y: 262, width: 166, height: 166), projection: projection(frames),
            boxLow: box.low, boxHigh: box.high, tableHeight: 0.04,
            behind: SurfaceLayout.Rect(x: 118, y: 440, width: 166, height: 120))
    }

    func testATapAsksForTheSamePlaceOfBothArms() {
        let first = panel(so), second = panel(b)
        var random = SplitMix64(seed: 12)
        for _ in 0..<100 {
            let x = random.uniform(118, 284), y = random.uniform(262, 428)
            let place = first.target(x: x, y: y, travelHeight: 0.05)
            assertEqual(second.target(x: x, y: y, travelHeight: 0.05), carry(place))
            XCTAssertEqual(first.inBox(place), second.inBox(carry(place)))
            XCTAssertEqual(first.point(over: place), second.point(over: carry(place)))
        }
    }

    func testATapOnTheViewFromBehindAimsAsTheSO101DoesCarried() {
        let first = panel(so), second = panel(b)
        let limits = ArbiterRig.goTo().goTo!
        let views = ViewAim(behindTopAboveTableM: 0.09)
        var random = SplitMix64(seed: 13)
        var targets = 0
        for _ in 0..<200 {
            let point = SIMD2(random.uniform(118, 284), random.uniform(440, 560))
            let here = first.projection.base(
                fromOperator: SIMD3(random.uniform(-0.08, 0.03), random.uniform(0.11, 0.24), random.uniform(0.02, 0.12))
            )
            let one = first.aimBehind(at: point, measured: here, limits: limits, views: views)
            let two = second.aimBehind(at: point, measured: carry(here), limits: limits, views: views)
            switch (one, two) {
            case (.target(let a), .target(let c)):
                assertEqual(c, carry(a))
                targets += 1
            default: XCTAssertEqual(one, two)
            }
        }
        XCTAssertGreaterThan(targets, 20)
    }

    // MARK: A going move

    private let limits = ArbiterRig.goTo().goTo!

    /// What the arm does with the point it is commanded to, in the operator's view: it follows, sags 12 mm, or is
    /// stopped by a wall 3 cm to the operator's left. One behaviour for both arms, since the operator sees one.
    private enum Arm: CaseIterable {
        case follows, sags, wall

        func respond(_ seen: SIMD3<Double>) -> SIMD3<Double> {
            switch self {
            case .follows: return seen
            case .sags: return seen - SIMD3(0, 0, 0.012)
            case .wall: return SIMD3(max(seen.x, -0.03), seen.y, seen.z)
            }
        }
    }

    private typealias Step = (commanded: SIMD3<Double>, link: SIMD3<Double>, verdict: GoMove.Verdict?)

    /// Drives a move the way the input rules' gate does, the arm answering the command of 0.2 s before, and keeps what
    /// the move said at every step.
    private func driven(
        _ frames: Frames, start: SIMD3<Double>, target: SIMD3<Double>, arm: Arm
    ) -> (steps: [Step], deadline: TimeInterval) {
        let box = TestFrames.carry((boxLow, boxHigh), from: so, to: frames)
        var move = GoMove(
            frames: frames, start: start, target: target, limits: limits, at: 0, boxLow: box.low, boxHigh: box.high)
        var steps: [Step] = []
        for i in 0..<1_500 {
            let now = Double(i) / 30
            let measured = frames.base(fromOperator: arm.respond(frames.operatorPoint(move.commanded(at: now - 0.2))))
            let verdict = move.observe(ArmFix(pinch: measured, ageS: 0.1, holdPaused: false), at: now)
            steps.append((move.commanded(at: now), move.linkOffset(at: now), verdict))
            if verdict != nil { break }
        }
        return (steps, move.deadline)
    }

    /// A going move, up or down first and then level, commands what the SO-101's does, carried, step by step, and
    /// ends the same way at the same moment: when the arm follows, when it sags below its command, and when a wall
    /// stops it short.
    func testAGoingMoveCommandsAndEndsAsTheSO101DoesCarried() {
        let starts = [SIMD3(0.02, -0.14, 0.10), SIMD3(0.06, -0.2, 0.05), SIMD3(-0.03, -0.1, 0.14)]
        let targets = [SIMD3(0.0, -0.18, 0.09), SIMD3(0.09, -0.12, 0.09), SIMD3(-0.04, -0.24, 0.09)]
        var ends = Set<String>()
        for (index, (start, target)) in zip(starts, targets).enumerated() {
            for arm in Arm.allCases {
                let one = driven(so, start: start, target: target, arm: arm)
                let two = driven(b, start: carry(start), target: carry(target), arm: arm)
                XCTAssertEqual(one.steps.count, two.steps.count, "\(index) \(arm)")
                XCTAssertEqual(one.deadline, two.deadline, accuracy: 1e-9, "\(index) \(arm)")
                for (i, (x, y)) in zip(one.steps, two.steps).enumerated() {
                    let place = "\(index) \(arm) step \(i)"
                    assertEqual(y.commanded, carry(x.commanded), "commanded \(place)")
                    assertEqual(y.link, TestFrames.carryLink(x.link, from: so, to: b), "link \(place)")
                    XCTAssertEqual(x.verdict, y.verdict, place)
                }
                ends.insert("\(arm) \(String(describing: one.steps.last?.verdict))")
            }
        }
        XCTAssertTrue(ends.contains("follows Optional(TeleopCore.GoMove.Verdict.arrived)"), "\(ends)")
        XCTAssertTrue(ends.contains("wall Optional(TeleopCore.GoMove.Verdict.stoppedShort)"), "\(ends)")
    }

    // MARK: Cues

    /// Every side of the work box is told from the same side of the operator's view, through whichever axis it lies.
    func testTheWorkAreaCueNamesTheSameSides() {
        let box = (low: SIMD3(-0.05, -0.25, 0.0), high: SIMD3(0.11, -0.09, 0.15))
        let carried = TestFrames.carry(box, from: so, to: b)
        var random = SplitMix64(seed: 14)
        var told = Set<OperatorDirection>()
        for sides in [Set(OperatorDirection.allCases), Set(OperatorDirection.allCases).subtracting([.down])] {
            var first = WorkAreaCue(frames: so, low: box.low, high: box.high, sides: sides)
            var second = WorkAreaCue(frames: b, low: carried.low, high: carried.high, sides: sides)
            var ms = 0
            for _ in 0..<400 {
                ms += 20
                let p = SIMD3(random.uniform(-0.1, 0.16), random.uniform(-0.3, -0.04), random.uniform(-0.04, 0.2))
                let one = first.commanded(p, at: ms)
                XCTAssertEqual(one, second.commanded(carry(p), at: ms), "\(p)")
                XCTAssertEqual(first.outside, second.outside, "\(p)")
                if let one { told.insert(one) }
            }
        }
        XCTAssertGreaterThanOrEqual(told.count, 4, "several sides were told, not just one")
    }

    // MARK: The feedback monitor

    private struct Told: Equatable {
        var ms: Int
        var event: FeedbackEvent
    }

    private struct Outcome: Equatable {
        var told: [Told]
        var lowest: Double?
        var lowestPinch: Double?
    }

    /// The lowest rule's scenarios as the SO-101's own tests drive them, every point carried to `frames`. A scenario
    /// is a list of stands: the arm, the command's gap from it, the first and last state time, the activity.
    private func lowest(
        _ frames: Frames,
        _ scenario: [(arm: SIMD3<Double>, gap: SIMD3<Double>, from: Int, through: Int, clamped: Bool)],
        pinch: SIMD3<Double>? = nil
    ) -> Outcome {
        var monitor = FeedbackMonitor(limits: GripperLimits(openDeg: 97, emptyDeg: 2), frames: frames)
        monitor.reportsLowest = true
        monitor.startSent(.pose, restart: false, at: 0)
        var told: [Told] = []
        for stand in scenario {
            let arm = TestFrames.carry(stand.arm, from: so, to: frames)
            let gap = TestFrames.carry(stand.gap, from: so, to: frames)
            let reported = pinch.map { TestFrames.carry(stand.arm + $0, from: so, to: frames) }
            for ms in Swift.stride(from: stand.from, through: stand.through, by: 200) {
                monitor.commanded(arm + gap)
                let state = ServerState(
                    activity: stand.clamped ? .poseClamped : .poseTracking, endEffector: arm, toolPoint: reported)
                told += monitor.observe(state, at: ms).map { Told(ms: ms, event: $0) }
            }
        }
        return Outcome(told: told, lowest: monitor.lowestSeen, lowestPinch: monitor.lowestPinchSeen)
    }

    func testTheLowestRuleTellsTheSameStallsAndKeepsTheSameHeights() {
        let onTable = SIMD3(0.02, -0.14, 0.133)
        let down = SIMD3(0.0, 0.0, -0.02)
        let scenarios:
            [(
                String, [(arm: SIMD3<Double>, gap: SIMD3<Double>, from: Int, through: Int, clamped: Bool)],
                SIMD3<Double>?
            )] =
                [
                    ("stall below", [(onTable, down, 200, 1_600, false)], nil),
                    (
                        "stall below with the pinch point reported", [(onTable, down, 200, 1_600, false)],
                        SIMD3(0.007, -0.036, -0.088)
                    ),
                    ("stall level", [(onTable, SIMD3(0.02, 0, 0), 200, 1_600, false)], nil),
                    ("stall sideways and down", [(onTable, SIMD3(0.007, 0, -0.008), 200, 1_600, false)], nil),
                    (
                        "after a clamp",
                        [
                            (onTable, SIMD3(0, 0, -0.06), 200, 200, false),
                            (onTable, SIMD3(0, 0, -0.06), 400, 1_800, true),
                        ],
                        nil
                    ),
                    (
                        "once per approach",
                        [
                            (onTable, down, 200, 1_600, false),
                            (onTable + SIMD3(0, 0, 0.009), SIMD3(0, 0, 0.01), 1_800, 2_200, false),
                            (onTable, down, 2_400, 4_400, false),
                            (onTable + SIMD3(0, 0, 0.01), SIMD3(0, 0, 0.01), 4_600, 4_800, false),
                            (onTable, down, 5_000, 6_000, false),
                        ], nil
                    ),
                    (
                        "coming down, then standing",
                        [
                            (onTable + SIMD3(0, 0, 0.03), SIMD3(0, 0, -0.01), 200, 200, false),
                            (onTable + SIMD3(0, 0, 0.02), SIMD3(0, 0, -0.01), 400, 400, false),
                            (onTable + SIMD3(0, 0, 0.01), SIMD3(0, 0, -0.01), 600, 600, false),
                            (onTable, down, 800, 2_400, false),
                        ], nil
                    ),
                ]
        var tellings = 0
        for (name, scenario, pinch) in scenarios {
            let one = lowest(so, scenario, pinch: pinch)
            let two = lowest(b, scenario, pinch: pinch)
            XCTAssertEqual(one, two, name)
            tellings += one.told.count
        }
        XCTAssertGreaterThanOrEqual(tellings, 8, "the scenarios do tell things")
    }
}

/// The same tests with an arm whose up is not along the base's z at all.
final class RulesAcrossFramesOnItsSideTests: RulesAcrossFramesTests {
    override var b: Frames { TestFrames.onItsSide }
}
