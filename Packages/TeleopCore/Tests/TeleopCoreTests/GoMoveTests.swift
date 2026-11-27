import XCTest
import simd
@testable import TeleopCore

/// A going move's path and its verdicts: up or down first, then level, at the profile's speed; a leg over by time,
/// never by comparing computed points; no command below the travel height once the first leg is over, a correction at
/// the end included; a stall judged only from positions measured after the command reached the leg's end, after the
/// last pause and after the start's grace, which runs from the later of the start and that pause's end; corrections
/// that move the command, never the target, on the way up or down only raise it, and never end outside the work box
/// the move was given.
final class GoMoveTests: XCTestCase {
    /// The SO-101 simulator's go numbers (the core tests cannot reach `RobotProfile`).
    private let limits = GoToLimits(
        travelHeightM: 0.05, speedMps: 0.04, arriveToleranceM: 0.008, corrections: 2, correctionReachM: 0.03,
        settleS: 0.6, timeFactor: 1.5, allowanceS: 3, armDataTimeoutS: 2, startGraceS: 1.5)
    /// The pinch point's travel height in the base frame: the profile's table, a `Float`, plus the travel height.
    private let travel = Double(Float(0.04)) + 0.05
    /// The input rules' gate runs this often.
    private let step = 1.0 / 30

    private func fix(_ pinch: SIMD3<Double>, age: Double = 0.1, paused: Bool = false) -> ArmFix {
        ArmFix(pinch: pinch, ageS: age, holdPaused: paused)
    }

    private func horizontal(_ v: SIMD3<Double>) -> SIMD2<Double> { SIMD2(v.x, v.y) }

    /// The lowest height the move may command in its current stage. The first leg runs between the start and the
    /// travel height, so it is never below the lower of the two; every stage after it, the corrections included, is
    /// never below the travel height.
    private func heightFloor(_ move: GoMove) -> Double {
        move.stage == .vertical ? min(move.start.z, move.target.z) : move.target.z
    }

    /// How a driven move ended.
    private enum End: Equatable {
        case verdict(GoMove.Verdict)
        /// The input rules' gate would end it at its deadline.
        case timeIsUp
        case goingOn
    }

    /// What a driven move did.
    private struct Run {
        var end: End
        var at: TimeInterval
        /// Every stage it passed through, in order, and when each began.
        var stages: [(stage: GoMove.Stage, at: TimeInterval)]
        /// The calls at which a correction was taken.
        var corrections: [TimeInterval]
    }

    /// Calls `observe` at every gate step from `from` until it gives a verdict, the deadline passes (judged after the
    /// verdict, as the gate does) or `until`. The arm is measured `age` before each call, where the command was `delay`
    /// before that, moved by `arm` (a sag, a wall). Every step also checks that the command never outruns its speed and
    /// that neither the command nor the end of its leg is below the travel height (`heightFloor`).
    private func drive(
        _ move: inout GoMove, from: TimeInterval = 0, until: TimeInterval = 60, age: Double = 0.1, delay: Double = 0.1,
        arm: (SIMD3<Double>) -> SIMD3<Double> = { $0 }, file: StaticString = #filePath, line: UInt = #line
    ) -> Run {
        var run = Run(end: .goingOn, at: from, stages: [(move.stage, from)], corrections: [])
        var i = 0
        var previous: (at: TimeInterval, offset: SIMD3<Double>)?
        while true {
            let now = from + Double(i) * step
            guard now <= until else { return run }
            run.at = now
            let measured = arm(move.commanded(at: now - age - delay))
            let commandBefore = move.commanded(at: now)
            let left = move.correctionsLeft
            let verdict = move.observe(fix(measured, age: age), at: now)
            XCTAssertEqual(
                move.commanded(at: now), commandBefore, "the command never jumps, at \(now)", file: file, line: line)
            if move.correctionsLeft < left { run.corrections.append(now) }
            if move.stage != run.stages.last?.stage { run.stages.append((move.stage, now)) }
            let offset = move.linkOffset(at: now)
            if let previous {
                XCTAssertLessThanOrEqual(
                    simd_distance(offset, previous.offset), limits.speedMps * (now - previous.at) + 1e-9,
                    "the command keeps to its speed, at \(now)", file: file, line: line)
            }
            previous = (now, offset)
            let floor = heightFloor(move)
            XCTAssertGreaterThanOrEqual(
                move.commanded(at: now).z, floor, "no command below the travel height, \(move.stage) at \(now)",
                file: file, line: line)
            XCTAssertGreaterThanOrEqual(
                move.commanded(at: .infinity).z, floor, "no leg ends below the travel height, \(move.stage) at \(now)",
                file: file, line: line)
            if let verdict {
                run.end = .verdict(verdict)
                return run
            }
            if now >= move.deadline {
                run.end = .timeIsUp
                return run
            }
            i += 1
        }
    }

    // MARK: - The path

    func testTheCommandGoesUpOrDownFirstAtTheProfileSpeed() {
        let start = SIMD3(0.03, -0.15, 0.13)
        let down = GoMove(
            frames: TestFrames.so101, start: start, target: SIMD3(0.06, -0.19, travel), limits: limits, at: 10)
        XCTAssertEqual(down.stage, .vertical)
        XCTAssertEqual(down.commanded(at: 10), start)
        let half = down.commanded(at: 10.5)
        XCTAssertEqual(horizontal(half), horizontal(start), "nothing level before the corner, exactly")
        XCTAssertEqual(half.z, 0.13 - 0.02, accuracy: 1e-12)
        for i in 1..<25 {
            let a = down.commanded(at: 10 + Double(i - 1) * step), b = down.commanded(at: 10 + Double(i) * step)
            XCTAssertEqual(simd_distance(a, b), limits.speedMps * step, accuracy: 1e-12, "\(i)")
            XCTAssertLessThan(b.z, a.z, "down, \(i)")
            XCTAssertEqual(horizontal(down.linkOffset(at: 10 + Double(i) * step)), .zero, "\(i)")
        }

        let low = SIMD3(0.0, -0.2, 0.06)
        let up = GoMove(
            frames: TestFrames.so101, start: low, target: SIMD3(-0.03, -0.12, travel), limits: limits, at: 0)
        XCTAssertEqual(up.commanded(at: 0.25).z, 0.07, accuracy: 1e-12)
        XCTAssertEqual(horizontal(up.commanded(at: 0.25)), horizontal(low))
    }

    func testTheCommandWaitsAtTheLegsEnd() {
        let start = SIMD3(0.03, -0.15, 0.13)
        var move = GoMove(
            frames: TestFrames.so101, start: start, target: SIMD3(0.06, -0.19, travel), limits: limits, at: 0)
        let corner = SIMD3(start.x, start.y, travel)
        // 4 cm at 0.04 m/s: the corner is reached after a second and the command stays there.
        XCTAssertNotEqual(move.commanded(at: 0.99), corner)
        for i in 0..<50 { XCTAssertEqual(move.commanded(at: 1.001 + Double(i) * 0.1), corner, "\(i)") }
        // An arm coming down, above the travel height, does not turn the corner before the command has reached it.
        for i in 0..<10 {
            let now = 0.6 + Double(i) * 0.04
            XCTAssertNil(move.observe(fix(SIMD3(start.x, start.y, 0.128 - 0.001 * Double(i))), at: now))
            XCTAssertEqual(move.stage, .vertical, "\(i)")
            XCTAssertEqual(move.commanded(at: now + 1), corner, "\(i)")
        }
        // Once it has, the level leg starts at once from the corner, at the travel height, with the arm still 2.8 cm
        // above it: being above the travel height is safe, and the arm goes on down as it moves.
        XCTAssertNil(move.observe(fix(SIMD3(start.x, start.y, 0.118)), at: 1.001))
        XCTAssertEqual(move.stage, .level)
        XCTAssertEqual(move.commanded(at: 1.001), corner)
        XCTAssertEqual(move.commanded(at: 1.5).z, travel)
        XCTAssertEqual(move.correctionsLeft, limits.corrections)
    }

    /// A leg whose ends have opposite signs: computed at the full share, its x is −0.01366251418693179, not the leg's
    /// end.
    /// Judged by time, the command is the leg's end exactly, so the settle is judged there and an arm held 12 mm short
    /// ends "stopped short" well before its deadline.
    func testALegEndsOnTimeWhenItsEndsHaveOppositeSigns() {
        let start = SIMD3(0.0962008168948672, -0.25068346387644874, 0.14471459357725738)
        let target = SIMD3(-0.013662514186931797, -0.2311489833285125, 0.08999999910593033)
        let corner = SIMD3(start.x, start.y, target.z)
        XCTAssertNotEqual(corner + (target - corner) * 1.0, target, "the case where a computed end misses")

        var move = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        // The vertical leg (5.5 cm) is over by 1.37 s; a fresh fix at the travel height turns the corner.
        XCTAssertNil(move.observe(fix(SIMD3(start.x, start.y, target.z + 0.001)), at: 1.4))
        XCTAssertEqual(move.stage, .level)
        XCTAssertEqual(move.commanded(at: 1.4), corner, "the level leg starts where the command waited")
        let levelEnds = 1.4 + simd_length(target - corner) / limits.speedMps
        XCTAssertNotEqual(move.commanded(at: levelEnds - 0.05), target)
        XCTAssertEqual(move.commanded(at: levelEnds), target, "at its length over the speed, exactly the end")
        XCTAssertEqual(move.commanded(at: levelEnds + 1), target)

        // A wall 12 mm before the target, across the level direction.
        let across = simd_normalize(target - corner)
        let wall = simd_dot(target - corner, across) - 0.012
        let run = drive(&move, from: 1.4 + step) { point in
            let along = simd_dot(point - corner, across)
            return along <= wall ? point : point - across * (along - wall)
        }
        XCTAssertEqual(run.end, .verdict(.stoppedShort))
        XCTAssertLessThan(run.at, move.deadline, "stopped short, not time is up")
        XCTAssertEqual(run.corrections.count, 2, "both corrections walked into the wall first")
        XCTAssertGreaterThan(run.corrections.first ?? 0, levelEnds + limits.settleS, "settled after the leg's end")
    }

    func testTheLevelLegWaitsForAMeasuredTravelHeight() {
        let start = SIMD3(0.02, -0.2, travel - 0.04)
        let target = SIMD3(0.07, -0.13, travel)
        let corner = SIMD3(start.x, start.y, travel)
        var move = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        // The command reaches the corner at 1 s; the arm lags and sits 2 cm low until 1.5 s.
        var now = 0.0
        while now <= 1.5 {
            let lagging = SIMD3(start.x, start.y, start.z + 0.02 * min(1, max(0, (now - 0.1) / 0.5)))
            XCTAssertNil(move.observe(fix(lagging), at: now))
            XCTAssertEqual(move.stage, .vertical, "\(now)")
            XCTAssertEqual(horizontal(move.linkOffset(at: now)), .zero, "no level motion, \(now)")
            now += step
        }
        XCTAssertEqual(move.commanded(at: 1.5), corner)
        // A fix at the travel height that is too old says nothing.
        XCTAssertNil(move.observe(fix(corner - SIMD3(0, 0, 0.001), age: 0.45), at: 1.55))
        XCTAssertEqual(move.stage, .vertical)
        XCTAssertEqual(horizontal(move.linkOffset(at: 1.55)), .zero)
        // A fresh one within 8 mm of it turns the corner, from where the command waited.
        XCTAssertNil(move.observe(fix(corner - SIMD3(0, 0, 0.007)), at: 1.6))
        XCTAssertEqual(move.stage, .level)
        XCTAssertEqual(move.commanded(at: 1.6), corner)
        let moved = move.commanded(at: 2.0)
        XCTAssertEqual(simd_distance(moved, corner), limits.speedMps * 0.4, accuracy: 1e-12)
        XCTAssertEqual(moved.z, travel, "level")
    }

    /// An arm that stands where it was tapped, 2.5 cm above the travel height (a start the server has not yet taken, a
    /// server that froze without saying so): the command is never lowered for it. The level leg starts as soon as the
    /// command reaches the corner and runs at the travel height, and the move stops short once the command has been at
    /// the target for the settle time with the arm still standing.
    func testAnArmStandingAboveTheTravelHeightIsNeverLowered() throws {
        let start = SIMD3(0.0, -0.2, travel + 0.025)
        let target = SIMD3(0.06, -0.15, travel)
        let corner = SIMD3(start.x, start.y, travel)
        var move = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        let run = drive(&move) { _ in start }
        XCTAssertEqual(run.stages.map { $0.stage }, [.vertical, .level])
        let turned = try XCTUnwrap(run.stages.last?.at)
        let cornerAt = 0.025 / limits.speedMps
        XCTAssertGreaterThanOrEqual(turned, cornerAt - 1e-9, "not before the command reached the corner")
        XCTAssertLessThan(turned, cornerAt + step, "at the first gate step after it")
        XCTAssertEqual(run.corrections, [], "no correction lowered the command")
        XCTAssertEqual(move.commanded(at: turned), corner)
        XCTAssertEqual(move.commanded(at: 100), target, "the level leg ends at the target, at the travel height")
        // The level leg ends 7.81 cm on; the arm, 8.2 cm from the target, is past the correction reach.
        let levelEnds = turned + simd_distance(corner, target) / limits.speedMps
        XCTAssertEqual(run.end, .verdict(.stoppedShort))
        XCTAssertGreaterThan(run.at, levelEnds + limits.settleS - 1e-9)
        XCTAssertLessThan(run.at, move.deadline)
    }

    func testArrivalNeedsAFreshFixWithinToleranceNotTheCommand() {
        let start = SIMD3(0.03, -0.15, travel)
        let target = SIMD3(0.05, -0.15, travel)
        var move = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        XCTAssertNil(move.observe(fix(start), at: 0))
        XCTAssertEqual(move.stage, .level, "no height to go: level at once")
        // The command reached the target at 0.5 s; the arm has not.
        XCTAssertEqual(move.commanded(at: 1.0), target)
        XCTAssertNil(move.observe(fix(target - SIMD3(0.009, 0, 0)), at: 1.0), "9 mm away is not there")
        XCTAssertNil(move.observe(fix(target, age: 0.41), at: 1.05), "an old fix at the target says nothing")
        XCTAssertEqual(move.observe(fix(target + SIMD3(0, 0.0079, 0), age: 0.4), at: 1.1), .arrived)

        // The measured arm decides, not the command: it can arrive while the command still travels.
        var early = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        XCTAssertNil(early.observe(fix(start), at: 0))
        XCTAssertNotEqual(early.commanded(at: 0.2), target)
        XCTAssertEqual(early.observe(fix(target - SIMD3(0.005, 0, 0)), at: 0.2), .arrived)
    }

    // MARK: - When a stall may be judged

    /// The link re-sending its start, or holding one back: a still arm then says nothing, and neither does a position
    /// measured before the pause ended.
    func testAPausedLinkIsNotASettle() throws {
        let start = SIMD3(0.0, -0.2, travel)
        let target = SIMD3(0.04, -0.2, travel)
        var move = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        let age = 0.3
        // The arm goes 2 cm along the 4 cm leg and is held there from 0.5 s.
        func arm(_ measuredAt: Double) -> SIMD3<Double> { SIMD3(min(0.04 * max(0, measuredAt), 0.02), -0.2, travel) }
        let pausedFrom = 1.0, pausedTo = 2.0
        var corrected: TimeInterval?
        for i in 0...100 {
            let now = Double(i) * step
            let paused = now > pausedFrom - step / 2 && now < pausedTo + step / 2
            let verdict = move.observe(fix(arm(now - age), age: age, paused: paused), at: now)
            XCTAssertNil(verdict, "\(now)")
            if paused { XCTAssertEqual(move.stage, .level, "no settle while paused, \(now)") }
            if corrected == nil, move.stage == .correcting(.level) { corrected = now }
        }
        // The first position measured after the pause, one gate step at most after it, anchors the settle, which then
        // takes 0.6 s of measured time.
        let first = try XCTUnwrap(corrected)
        XCTAssertGreaterThan(first, pausedTo + age + limits.settleS - 1e-9)
        XCTAssertLessThan(first, pausedTo + age + limits.settleS + 3 * step)
    }

    /// Standing still is seen, not assumed: a gap in the positions longer than their freshness restarts the settle,
    /// even when the next position is within 2 mm of the first.
    func testAGapInThePositionsRestartsTheSettle() {
        let start = SIMD3(0.0, -0.2, travel)
        let target = SIMD3(0.04, -0.2, travel)
        var move = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        let held = SIMD3(0.02, -0.2, travel)
        XCTAssertNil(move.observe(fix(start), at: 0))
        XCTAssertEqual(move.stage, .level)
        // The leg's command is over at 1 s; the arm stands 2 cm short and is measured at 1.2 s.
        XCTAssertNil(move.observe(fix(held, age: 0.1), at: 1.3))
        // No new position for a while: the newest one goes stale.
        XCTAssertNil(move.observe(fix(held, age: 0.5), at: 1.7))
        // The next one, 0.7 s after the first and 1 mm from it, starts a new settle instead of ending one.
        XCTAssertNil(move.observe(fix(held + SIMD3(0, 0.001, 0), age: 0.1), at: 2.0))
        XCTAssertEqual(move.stage, .level)
        XCTAssertEqual(move.correctionsLeft, limits.corrections)
        // Seen standing for 0.6 s from there, it has settled short.
        XCTAssertNil(move.observe(fix(held, age: 0.1), at: 2.6))
        XCTAssertEqual(move.stage, .correcting(.level))
    }

    func testPositionsMeasuredBeforeTheLegsEndAreNotASettle() {
        let start = SIMD3(0.0, -0.2, travel - 0.04)
        let target = SIMD3(0.03, -0.18, travel)
        var move = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        // The arm moved 3 mm, so the start's grace is over, and stuck there; its states arrive 0.39 s after they were
        // measured, so those measured while the command still travelled keep arriving after it reached the corner.
        let stuck = start + SIMD3(0, 0, 0.003)
        let age = 0.39
        let legEnds = 0.04 / limits.speedMps
        var ended: (verdict: GoMove.Verdict, at: TimeInterval)?
        for i in 0...120 where ended == nil {
            let now = Double(i) * step
            if let verdict = move.observe(fix(stuck, age: age), at: now) { ended = (verdict, now) }
            if ended == nil { XCTAssertEqual(move.stage, .vertical, "\(now)") }
        }
        // 3.7 cm short is past the correction reach: stopped short, once positions measured after the leg's end have
        // held still for 0.6 s.
        XCTAssertEqual(ended?.verdict, .stoppedShort)
        XCTAssertGreaterThan(ended?.at ?? 0, legEnds + age + limits.settleS - 1e-9)
        XCTAssertLessThan(ended?.at ?? .infinity, legEnds + age + limits.settleS + 2 * step)
    }

    /// A 9 mm leg up, with the arm still for 1.4 s after the tap and every state 0.38 s old: no verdict, and no
    /// correction that would carry a wrong height into the level leg.
    func testASlowStartIsNotAStall() {
        let start = SIMD3(0.01, -0.17, travel - 0.009)
        let target = SIMD3(0.05, -0.12, travel)
        let age = 0.38
        func lateArm(_ measuredAt: Double) -> SIMD3<Double> {
            SIMD3(start.x, start.y, min(travel, start.z + limits.speedMps * max(0, measuredAt - 1.4)))
        }
        var move = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        for i in 0...75 {
            let now = Double(i) * step
            XCTAssertNil(move.observe(fix(lateArm(now - age), age: age), at: now), "\(now)")
            XCTAssertEqual(move.correctionsLeft, limits.corrections, "\(now)")
        }
        XCTAssertEqual(move.stage, .level, "the corner was turned once the arm rose")
        XCTAssertEqual(move.commanded(at: 10).z, target.z, "and the level leg runs at the travel height, exactly")

        // An arm that never moves: a stall is judged only from positions measured after the start plus 1.5 s.
        var still = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        var judged: TimeInterval?
        for i in 0...120 where judged == nil {
            let now = Double(i) * step
            XCTAssertNil(still.observe(fix(start, age: age), at: now), "\(now)")
            if still.stage != .vertical { judged = now }
        }
        XCTAssertEqual(still.stage, .correcting(.vertical))
        XCTAssertGreaterThan(judged ?? 0, limits.startGraceS + limits.settleS + age - 1e-9)
        XCTAssertLessThan(judged ?? .infinity, limits.startGraceS + limits.settleS + age + 2 * step)

        // With no grace at all, the fix taken at the tap still never anchors a settle: the tap's state measured 0.137 s
        // before it, seen again at 0.242 s, then the arm 1.2 mm up at 0.62 s, then within 8 mm of the travel height.
        var noGrace = limits
        noGrace.startGraceS = 0
        let traced = SIMD3(0.02, -0.15, 0.0806)
        var replay = GoMove(
            frames: TestFrames.so101, start: traced, target: SIMD3(0.04, -0.2, 0.09), limits: noGrace, at: 0)
        XCTAssertNil(replay.observe(fix(traced, age: 0.137), at: 0))
        XCTAssertNil(replay.observe(fix(traced, age: 0.379), at: 0.242))
        XCTAssertNil(replay.observe(fix(traced + SIMD3(0, 0, 0.0012), age: 0.022), at: 0.642))
        XCTAssertEqual(replay.stage, .vertical, "no correction from the tap's own state")
        XCTAssertNil(replay.observe(fix(SIMD3(traced.x, traced.y, 0.0834), age: 0.086), at: 0.876))
        XCTAssertEqual(replay.stage, .level)
        XCTAssertEqual(replay.commanded(at: 10).z, 0.09, "the level leg is not lifted by a false correction")
    }

    func testTheGraceEndsOnceTheArmHasMovedTwoMillimetres() {
        let start = SIMD3(0.01, -0.17, travel - 0.009)
        let target = SIMD3(0.05, -0.12, travel)
        // The jaws swing 2 mm sideways at 0.2 s and stay there, the height not reached.
        func firstJudgement(swing: Double) -> TimeInterval? {
            var move = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
            let swung = start + SIMD3(swing, 0, 0)
            XCTAssertNil(move.observe(fix(start, age: 0), at: 0))
            XCTAssertNil(move.observe(fix(swung, age: 0), at: 0.2))
            for i in 0...90 {
                let now = 0.3 + Double(i) * step
                XCTAssertNil(move.observe(fix(swung, age: 0), at: now))
                if move.stage != .vertical { return now }
            }
            return nil
        }
        let moved = firstJudgement(swing: 0.00205)
        XCTAssertGreaterThan(moved ?? 0, 0.3 + limits.settleS - 1e-9, "settled from the first fix after the leg's end")
        XCTAssertLessThan(moved ?? .infinity, 0.3 + limits.settleS + 2 * step, "about 0.9 s, inside the 1.5 s grace")
        let notMoved = firstJudgement(swing: 0.00195)
        XCTAssertGreaterThan(notMoved ?? .infinity, limits.startGraceS + limits.settleS - 1e-9, "1.95 mm is not moving")
    }

    /// A start the link holds back for 0.8 s, which the server then takes 1.4 s late: each delay is within its own
    /// limit, so the grace runs from the end of the pause, not from the tap, and the arm is not taken for stalled.
    func testTheGraceRunsFromTheEndOfTheLastPause() throws {
        let start = SIMD3(0.01, -0.17, travel - 0.009)
        let target = SIMD3(0.05, -0.12, travel)
        let age = 0.38
        let heldBack = 0.8
        func lateArm(_ measuredAt: Double) -> SIMD3<Double> {
            SIMD3(start.x, start.y, min(travel, start.z + limits.speedMps * max(0, measuredAt - heldBack - 1.4)))
        }
        var move = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        for i in 0...90 {
            let now = Double(i) * step
            XCTAssertNil(move.observe(fix(lateArm(now - age), age: age, paused: now < heldBack), at: now), "\(now)")
            XCTAssertEqual(move.correctionsLeft, limits.corrections, "\(now)")
        }
        XCTAssertEqual(move.stage, .level, "the corner was turned once the arm rose")
        XCTAssertEqual(move.commanded(at: 10).z, travel, "and the level leg runs at the travel height, exactly")

        // An arm that never moves: the first stall is judged only from positions measured 1.5 s after the last paused
        // call; the next one from positions measured after the correction's leg reached its end, with no new grace.
        var still = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        var lastPaused = -Double.infinity
        var corrections: [TimeInterval] = []
        for i in 0...240 where corrections.count < 2 {
            let now = Double(i) * step
            if now < heldBack { lastPaused = now }
            let left = still.correctionsLeft
            XCTAssertNil(still.observe(fix(start, age: age, paused: now < heldBack), at: now), "\(now)")
            if still.correctionsLeft < left { corrections.append(now) }
        }
        XCTAssertEqual(corrections.count, 2)
        let first = try XCTUnwrap(corrections.first)
        XCTAssertGreaterThan(first, lastPaused + limits.startGraceS + age + limits.settleS - 1e-9)
        XCTAssertLessThan(first, lastPaused + limits.startGraceS + age + limits.settleS + 2 * step)
        let legEnds = first + 0.009 / limits.speedMps
        let second = try XCTUnwrap(corrections.last)
        XCTAssertGreaterThan(second, legEnds + age + limits.settleS - 1e-9)
        XCTAssertLessThan(second, legEnds + age + limits.settleS + 2 * step)
    }

    // MARK: - Corrections

    /// The jaws sag 9 mm below the command on the way up: the move settles 9 mm low, the correction raises the
    /// command, the level leg keeps that offset, and arrival is still the measured point against the tapped target.
    func testAVerticalCorrectionMovesOnlyTheCommandedHeight() throws {
        let start = SIMD3(0.02, -0.2, travel - 0.03)
        let target = SIMD3(0.06, -0.15, travel)
        var move = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        let sag: (SIMD3<Double>) -> SIMD3<Double> = { SIMD3($0.x, $0.y, max(start.z, $0.z - 0.009)) }
        let run = drive(&move, arm: sag)
        XCTAssertEqual(run.end, .verdict(.arrived))
        XCTAssertEqual(run.stages.map { $0.stage }, [.vertical, .correcting(.vertical), .level])
        XCTAssertEqual(move.target, target, "the target never moves")
        XCTAssertEqual(move.correctionsLeft, limits.corrections - 1)
        let raised = move.commanded(at: 100)
        XCTAssertEqual(horizontal(raised), horizontal(target))
        XCTAssertEqual(raised.z, travel + 0.009, accuracy: 1e-9, "the command holds the height offset at the end")

        // Step by step: a fix at the commanded end is 9 mm from the target, so it has not arrived; one at the target
        // has.
        var stepwise = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        let corrected = try XCTUnwrap(run.stages.first { $0.stage == .correcting(.vertical) }?.at)
        let level = try XCTUnwrap(run.stages.first { $0.stage == .level }?.at)
        XCTAssertLessThan(corrected, level)
        _ = drive(&stepwise, until: level, arm: sag)
        XCTAssertEqual(stepwise.stage, .level)
        let levelZ = stepwise.commanded(at: level + 0.5).z
        XCTAssertEqual(levelZ, stepwise.commanded(at: 100).z, "the level leg's command keeps the height offset")
        XCTAssertNil(stepwise.observe(fix(stepwise.commanded(at: 100), age: 0.1), at: 100))
        XCTAssertEqual(stepwise.observe(fix(target, age: 0.1), at: 100.1), .arrived)
    }

    /// The SO-101 allows two: one goes to holding the height, one to the end, and a wall still in the way then stops
    /// the move short.
    func testTwoCorrectionsOneForTheHeightOneForTheEnd() {
        let start = SIMD3(0.02, -0.2, travel - 0.03)
        let target = SIMD3(0.07, -0.15, travel)
        let corner = SIMD3(start.x, start.y, travel)
        let across = simd_normalize(target - corner)
        let wall = simd_dot(target - corner, across) - 0.012
        var move = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        let run = drive(&move) { command in
            let sagged = SIMD3(command.x, command.y, max(start.z, command.z - 0.009))
            let along = simd_dot(sagged - corner, across)
            return along <= wall ? sagged : sagged - across * (along - wall)
        }
        XCTAssertEqual(run.end, .verdict(.stoppedShort))
        XCTAssertEqual(
            run.stages.map { $0.stage }, [.vertical, .correcting(.vertical), .level, .correcting(.level)])
        XCTAssertEqual(run.corrections.count, 2)
        XCTAssertEqual(move.correctionsLeft, 0)
        XCTAssertLessThan(run.at, move.deadline)
        // The correction at the end moved the raised end of the level leg by the remainder, 12 mm across: the 9 mm
        // raise is kept.
        let end = move.commanded(at: 100)
        XCTAssertEqual(end.z, travel + 0.009, accuracy: 1e-9, "the correction at the end keeps the raise")
        XCTAssertEqual(simd_distance(horizontal(end), horizontal(target)), 0.012, accuracy: 1e-9)
    }

    /// An arm that rises only 45 per cent of the height asked of it settles low twice on the way up: 16.5 mm short,
    /// then, raised by that, 9.075 mm short. The raises add up, and the level leg runs at the travel height plus both.
    func testTwoRaisesOnTheWayUpAddUp() throws {
        let start = SIMD3(0.02, -0.2, travel - 0.03)
        let target = SIMD3(0.06, -0.15, travel)
        let weak: (SIMD3<Double>) -> SIMD3<Double> = { SIMD3($0.x, $0.y, start.z + 0.45 * max(0, $0.z - start.z)) }
        var move = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        let run = drive(&move, arm: weak)
        XCTAssertEqual(run.end, .verdict(.arrived))
        XCTAssertEqual(run.stages.map { $0.stage }, [.vertical, .correcting(.vertical), .level])
        XCTAssertEqual(run.corrections.count, 2)
        let second = try XCTUnwrap(run.corrections.last)
        let level = try XCTUnwrap(run.stages.last?.at)
        XCTAssertLessThan(second, level, "both on the way up")

        var once = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        _ = drive(&once, until: second - step / 2, arm: weak)
        XCTAssertEqual(once.correctionsLeft, limits.corrections - 1)
        let raisedOnce = once.commanded(at: 100)
        XCTAssertEqual(horizontal(raisedOnce), horizontal(start), "straight up")
        XCTAssertEqual(raisedOnce.z, travel + 0.0165, accuracy: 1e-9, "raised by the height first missing")
        var twice = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        _ = drive(&twice, until: level, arm: weak)
        XCTAssertEqual(twice.stage, .level)
        XCTAssertEqual(twice.commanded(at: level).z, travel + 0.025575, accuracy: 1e-9, "the level leg keeps both")
        XCTAssertEqual(twice.commanded(at: 100).z, travel + 0.025575, accuracy: 1e-9)
        XCTAssertEqual(horizontal(twice.commanded(at: 100)), horizontal(target))
    }

    /// Something under the whole way holds the jaws 2 cm above the travel height, below a start 4 cm above it: the arm
    /// comes down onto it, slides across on it and settles over the target, 2 cm too high. Neither correction presses
    /// the command down into it: the command stays at the target, and the move stops short. With the obstacle 3.5 cm
    /// up, past the correction reach, it stops short with no correction at all.
    func testAnObstacleAboveTheTravelHeightIsNeverPressedInto() {
        let start = SIMD3(0.0, -0.2, travel + 0.04)
        let target = SIMD3(0.06, -0.15, travel)
        var move = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        let run = drive(&move) { SIMD3($0.x, $0.y, max($0.z, self.travel + 0.02)) }
        XCTAssertEqual(run.end, .verdict(.stoppedShort))
        XCTAssertLessThan(run.at, move.deadline, "stopped short, not time is up")
        XCTAssertEqual(run.stages.map { $0.stage }, [.vertical, .level, .correcting(.level)])
        XCTAssertEqual(run.corrections.count, 2)
        XCTAssertEqual(move.commanded(at: 100), target, "across by nothing, and not down")

        var higher = GoMove(
            frames: TestFrames.so101, start: SIMD3(0.0, -0.2, travel + 0.05), target: target, limits: limits, at: 0)
        let higherRun = drive(&higher) { SIMD3($0.x, $0.y, max($0.z, self.travel + 0.035)) }
        XCTAssertEqual(higherRun.end, .verdict(.stoppedShort))
        XCTAssertEqual(higherRun.corrections, [])
        XCTAssertEqual(higher.commanded(at: 100), target)
    }

    /// Jaws that sag 9 mm are raised on the way up; then something under the target holds them 1.5 cm above the
    /// travel height. The correction at the end goes down by the 9 mm raise and stops at the travel height, not below
    /// it, and the move stops short. A raise that was false comes down the same way and the arm arrives: the server
    /// held the arm still below the travel height for a while without saying so, the move took that for sagging jaws
    /// and raised the command, and the arm, following again, stood that raise above the target.
    func testACorrectionAtTheEndComesDownToTheTravelHeightAndNeverBelow() throws {
        let start = SIMD3(0.02, -0.2, travel - 0.03)
        let target = SIMD3(0.06, -0.15, travel)
        var move = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        let run = drive(&move) { command in
            let sagged = SIMD3(command.x, command.y, max(start.z, command.z - 0.009))
            guard simd_distance(self.horizontal(sagged), self.horizontal(target)) <= 0.01 else { return sagged }
            return SIMD3(sagged.x, sagged.y, max(sagged.z, self.travel + 0.015))
        }
        XCTAssertEqual(run.end, .verdict(.stoppedShort))
        XCTAssertEqual(
            run.stages.map { $0.stage }, [.vertical, .correcting(.vertical), .level, .correcting(.level)])
        let end = move.commanded(at: 100)
        XCTAssertEqual(horizontal(end), horizontal(target))
        XCTAssertEqual(end.z, travel, "down to the travel height, exactly, and not below it")

        // Held still part way up from 0.8 s to 2.2 s: one raise on the way up, a level leg too high to arrive on, and
        // the correction at the end, which brings it down.
        var model = ModelledArm(oneWay: 0.05, tau: 0.3)
        model.frozen = 0.8...2.2
        let outcome = simulate(from: start, to: target, model, "a false raise")
        let raise = try XCTUnwrap(outcome.lowestLevel) - travel
        XCTAssertGreaterThan(raise, limits.arriveToleranceM, "the level leg ran too high to arrive on")
        XCTAssertEqual(outcome.corrections, 2)
        XCTAssertEqual(outcome.end, .verdict(.arrived))
    }

    /// Something under the target holds the jaws 2 cm above the travel height. Each correction at the end would go
    /// 2 cm down; the floor at the travel height leaves it no length at all, yet the time limit grows by the whole
    /// remainder, its length over the speed times the factor, plus the settle time.
    func testAFlooredCorrectionAtTheEndExtendsTheDeadlineByTheWholeRemainder() {
        let start = SIMD3(0.0, -0.2, travel + 0.04)
        let target = SIMD3(0.06, -0.15, travel)
        var move = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        let initial = move.deadline
        let run = drive(&move) { SIMD3($0.x, $0.y, max($0.z, self.travel + 0.02)) }
        XCTAssertEqual(run.end, .verdict(.stoppedShort))
        XCTAssertEqual(run.corrections.count, 2)
        XCTAssertEqual(move.commanded(at: 100), target, "neither correction moved the command")
        XCTAssertEqual(move.deadline, initial + 2 * (0.02 / 0.04 * 1.5 + 0.6), accuracy: 1e-9)
    }

    /// Jaws that sag 9 mm, and further the further out they reach: raised 9 mm on the way up, they still hang 12.8 mm
    /// low over the target. The correction at the end raises the command by that, and the arm arrives.
    func testJawsThatHangLowAtTheEndAreRaisedThereAndArrive() {
        let start = SIMD3(0.02, -0.2, travel - 0.03)
        let target = SIMD3(0.06, -0.15, travel)
        var move = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        let run = drive(&move) { command in
            let reach = simd_distance(self.horizontal(command), self.horizontal(start))
            return SIMD3(command.x, command.y, max(start.z, command.z - 0.009 - 0.2 * reach))
        }
        XCTAssertEqual(run.end, .verdict(.arrived))
        XCTAssertEqual(
            run.stages.map { $0.stage }, [.vertical, .correcting(.vertical), .level, .correcting(.level)])
        let end = move.commanded(at: 100)
        XCTAssertEqual(horizontal(end), horizontal(target))
        let hanging = 0.2 * simd_distance(horizontal(target), horizontal(start))
        XCTAssertEqual(end.z, travel + 0.009 + hanging, accuracy: 1e-9, "raised on the way up, then at the end")
    }

    func testSettledShortCorrectsUntilTheBudgetIsSpentThenStopsShort() {
        let start = SIMD3(-0.02, -0.22, travel)
        let target = SIMD3(0.02, -0.22, travel)
        for budget in 0...3 {
            var numbers = limits
            numbers.corrections = budget
            var move = GoMove(frames: TestFrames.so101, start: start, target: target, limits: numbers, at: 0)
            // A wall 1 cm before the target: each remainder is within the 3 cm reach.
            let run = drive(&move) { SIMD3(min($0.x, target.x - 0.01), $0.y, $0.z) }
            XCTAssertEqual(run.end, .verdict(.stoppedShort), "budget \(budget)")
            XCTAssertEqual(run.corrections.count, budget, "budget \(budget)")
            XCTAssertEqual(move.correctionsLeft, 0, "budget \(budget)")
            XCTAssertLessThan(run.at, move.deadline, "budget \(budget)")
        }
    }

    func testACorrectionIsWalkedNotJumped() throws {
        let start = SIMD3(-0.02, -0.22, travel)
        let target = SIMD3(0.02, -0.22, travel)
        var move = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        let run = drive(&move, until: 2.2) { SIMD3(min($0.x, target.x - 0.01), $0.y, $0.z) }
        XCTAssertEqual(run.corrections.count, 1)
        let at = try XCTUnwrap(run.corrections.first)
        XCTAssertEqual(move.stage, .correcting(.level))
        // `drive` checked that the command did not move in the call that took the correction; from there it walks.
        let from = move.commanded(at: at)
        XCTAssertEqual(from, target, "the correction starts where the level leg's command waited")
        for i in 1...4 {
            let now = at + Double(i) * 0.05
            XCTAssertEqual(
                simd_distance(move.commanded(at: now), from), limits.speedMps * Double(i) * 0.05, accuracy: 1e-12)
        }
        // The remainder was the target less the measured point, 1 cm: the leg's end moved by it.
        XCTAssertEqual(move.commanded(at: at + 1).x, target.x + 0.01, accuracy: 1e-9)
    }

    func testARemainderBeyondTheReachStopsShortAtOnce() {
        // Level: a wall 4 cm before the end of a 6 cm leg.
        let start = SIMD3(-0.04, -0.2, travel)
        var level = GoMove(
            frames: TestFrames.so101, start: start, target: SIMD3(0.02, -0.2, travel), limits: limits, at: 0)
        let levelRun = drive(&level) { SIMD3(min($0.x, -0.02), $0.y, $0.z) }
        XCTAssertEqual(levelRun.end, .verdict(.stoppedShort))
        XCTAssertEqual(levelRun.corrections, [])
        XCTAssertEqual(level.correctionsLeft, limits.corrections)

        // Vertical: the arm stops 3.5 cm short of the travel height.
        let low = SIMD3(0.0, -0.2, travel - 0.045)
        var vertical = GoMove(
            frames: TestFrames.so101, start: low, target: SIMD3(0.03, -0.18, travel), limits: limits, at: 0)
        let verticalRun = drive(&vertical) { SIMD3($0.x, $0.y, min($0.z, travel - 0.035)) }
        XCTAssertEqual(verticalRun.end, .verdict(.stoppedShort))
        XCTAssertEqual(verticalRun.corrections, [])
        XCTAssertEqual(verticalRun.stages.map { $0.stage }, [.vertical])
    }

    /// How far `point` lies outside the box from `low` to `high` on its farthest axis, metres; zero or less inside.
    private func past(_ point: SIMD3<Double>, _ low: SIMD3<Double>, _ high: SIMD3<Double>) -> Double {
        max((point - high).max(), (low - point).max())
    }

    /// A target 1 cm inside a face of the work box the move was given, and an arm held 2 cm short of it, as by a server
    /// whose box is smaller: each correction at the end would send the command another 2 cm on, out past the face.
    /// Every correction ends on the face instead, the arm settles short again, and once the profile's corrections are
    /// spent the move stops short. Under the box's top a raise on the way up stops at the top in the same way: jaws
    /// that hang 2 cm low get 5 mm of it, then nothing, and the move stops short.
    func testACorrectionNeverTakesTheCommandOutOfTheBox() {
        let low = SIMD3(-0.05, -0.26, -0.01)
        let high = SIMD3(0.11, -0.1, travel + 0.06)
        let start = SIMD3(0.04, -0.2, travel)
        let target = SIMD3(high.x - 0.01, start.y, travel)
        var move = GoMove(
            frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0, boxLow: low, boxHigh: high)
        var farthest = -Double.infinity
        let run = drive(&move) { command in
            farthest = max(farthest, self.past(command, low, high))
            return SIMD3(min(command.x, target.x - 0.02), command.y, command.z)
        }
        XCTAssertEqual(run.end, .verdict(.stoppedShort))
        XCTAssertLessThan(run.at, move.deadline, "stopped short, not time is up")
        XCTAssertEqual(run.stages.map { $0.stage }, [.vertical, .level, .correcting(.level)])
        XCTAssertEqual(run.corrections.count, limits.corrections, "at most the profile's corrections")
        XCTAssertLessThanOrEqual(farthest, 1e-12, "no commanded point outside the box")
        XCTAssertEqual(move.commanded(at: 100), SIMD3(high.x, start.y, travel), "the last correction ends on the face")

        let top = SIMD3(high.x, high.y, travel + 0.005)
        let below = SIMD3(0.02, -0.2, travel - 0.03)
        var up = GoMove(
            frames: TestFrames.so101,
            start: below, target: SIMD3(0.06, -0.15, travel), limits: limits, at: 0, boxLow: low, boxHigh: top)
        var highest = -Double.infinity
        let upRun = drive(&up) { command in
            highest = max(highest, self.past(command, low, top))
            return SIMD3(command.x, command.y, max(below.z, command.z - 0.02))
        }
        XCTAssertEqual(upRun.end, .verdict(.stoppedShort))
        XCTAssertLessThan(upRun.at, up.deadline, "stopped short, not time is up")
        XCTAssertEqual(upRun.stages.map { $0.stage }, [.vertical, .correcting(.vertical)])
        XCTAssertEqual(upRun.corrections.count, limits.corrections, "at most the profile's corrections")
        XCTAssertLessThanOrEqual(highest, 1e-12, "no commanded point above the box's top")
        XCTAssertEqual(up.commanded(at: 100), SIMD3(below.x, below.y, top.z), "raised to the top and no higher")
    }

    /// The box's top lies 1 cm above the travel height, and the jaws hang 2 cm low once the level leg is under way: the
    /// correction at the end would raise the command by the 2 cm missing, 1 cm past the top. It ends at the top
    /// instead, the jaws still hang 1 cm low, and once the profile's corrections are spent the move stops short. No
    /// commanded point lies above the top.
    func testACorrectionAtTheEndNeverRaisesTheCommandAboveTheBoxTop() {
        let low = SIMD3(-0.05, -0.26, -0.01)
        let high = SIMD3(0.11, -0.1, travel + 0.01)
        let start = SIMD3(0.0, -0.2, travel)
        let target = SIMD3(0.06, -0.2, travel)
        var move = GoMove(
            frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0, boxLow: low, boxHigh: high)
        var highest = -Double.infinity
        let run = drive(&move) { command in
            highest = max(highest, command.z)
            return command.x > start.x + 0.005 ? command - SIMD3(0, 0, 0.02) : command
        }
        XCTAssertEqual(run.end, .verdict(.stoppedShort))
        XCTAssertLessThan(run.at, move.deadline, "stopped short, not time is up")
        XCTAssertEqual(run.stages.map { $0.stage }, [.vertical, .level, .correcting(.level)])
        XCTAssertEqual(run.corrections.count, limits.corrections, "at most the profile's corrections")
        XCTAssertLessThanOrEqual(highest, high.z + 1e-12, "no commanded point above the box's top")
        XCTAssertEqual(move.commanded(at: 100), SIMD3(target.x, target.y, high.z), "raised to the top and no higher")
    }

    // MARK: - Arm data, the deadline, the frame

    func testNoFixOrAStaleFixForTheTimeoutIsNoArmData() {
        let start = SIMD3(0.0, -0.2, travel - 0.02)
        let target = SIMD3(0.03, -0.18, travel)
        var move = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        XCTAssertEqual(move.observe(nil, at: 0.1), .noArmData)
        move = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        XCTAssertNil(move.observe(fix(start, age: 2.0), at: 0.1), "2 s old is not yet too old")
        XCTAssertEqual(move.observe(fix(start, age: 2.001), at: 0.2), .noArmData)
        move = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        XCTAssertEqual(move.observe(fix(start, age: .nan), at: 0.1), .noArmData)

        // Positions stop arriving at 1 s: the move ends at the first call more than 2 s after the last one measured.
        move = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        var ended: (verdict: GoMove.Verdict, at: TimeInterval)?
        for i in 0...150 where ended == nil {
            let now = Double(i) * step
            let measuredAt = min(now - 0.1, 1.0)
            let arm = move.commanded(at: measuredAt - 0.1)
            if let verdict = move.observe(fix(arm, age: now - measuredAt), at: now) { ended = (verdict, now) }
        }
        XCTAssertEqual(ended?.verdict, .noArmData)
        XCTAssertGreaterThan(ended?.at ?? 0, 1.0 + limits.armDataTimeoutS)
        XCTAssertLessThan(ended?.at ?? .infinity, 1.0 + limits.armDataTimeoutS + 1.5 * step)
    }

    func testTheDeadlineIsPathOverSpeedTimesFactorPlusAllowance() {
        // 4 cm down, then 5 cm across: 0.09 m at 0.04 m/s is 2.25 s; times 1.5, plus 3 s.
        let move = GoMove(
            frames: TestFrames.so101,
            start: SIMD3(0.03, -0.15, travel + 0.04), target: SIMD3(0.06, -0.19, travel), limits: limits, at: 10)
        XCTAssertEqual(move.deadline, 10 + 2.25 * 1.5 + 3, accuracy: 1e-9)
        XCTAssertEqual(move.startedAt, 10)
        var other = limits
        other.timeFactor = 2
        other.allowanceS = 0.5
        let slower = GoMove(
            frames: TestFrames.so101,
            start: SIMD3(0.03, -0.15, travel + 0.04), target: SIMD3(0.06, -0.19, travel), limits: other, at: 0)
        XCTAssertEqual(slower.deadline, 2.25 * 2 + 0.5, accuracy: 1e-9)
    }

    func testACorrectionExtendsTheDeadline() {
        let start = SIMD3(-0.02, -0.22, travel)
        let target = SIMD3(0.02, -0.22, travel)
        var move = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        let before = move.deadline
        XCTAssertEqual(before, 0.04 / 0.04 * 1.5 + 3, accuracy: 1e-9)
        let run = drive(&move, until: 2.2) { SIMD3(min($0.x, target.x - 0.01), $0.y, $0.z) }
        XCTAssertEqual(run.corrections.count, 1)
        // A 1 cm remainder: its length over the speed times the factor, plus the settle time.
        XCTAssertEqual(move.deadline, before + 0.01 / 0.04 * 1.5 + 0.6, accuracy: 1e-9)

        // A raise on the way up extends it the same way: jaws that sag 9 mm settle 9 mm low.
        let low = SIMD3(0.02, -0.2, travel - 0.03)
        var up = GoMove(frames: TestFrames.so101, start: low, target: SIMD3(0.06, -0.15, travel), limits: limits, at: 0)
        let initial = up.deadline
        let upRun = drive(&up) { SIMD3($0.x, $0.y, max(low.z, $0.z - 0.009)) }
        XCTAssertEqual(upRun.end, .verdict(.arrived))
        XCTAssertEqual(upRun.stages.map { $0.stage }, [.vertical, .correcting(.vertical), .level])
        XCTAssertEqual(up.deadline, initial + 0.009 / 0.04 * 1.5 + 0.6, accuracy: 1e-9)
    }

    func testTheOffsetIsInTheLinksFrame() {
        let start = SIMD3(0.03, -0.15, travel + 0.04)
        let target = SIMD3(0.06, -0.19, travel)
        var move = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        XCTAssertEqual(move.linkOffset(at: 0), .zero)
        // Down 2 cm in the base frame is +2 cm in the link's frame (`TestFrames.so101.link(fromBase:)` flips z).
        let down = move.linkOffset(at: 0.5)
        XCTAssertEqual(down.z, 0.02, accuracy: 1e-12)
        XCTAssertEqual(down.x, 0)
        XCTAssertEqual(down.y, 0)
        XCTAssertNil(move.observe(fix(SIMD3(start.x, start.y, travel)), at: 1.1))
        XCTAssertEqual(move.stage, .level)
        let end = move.linkOffset(at: 100)
        XCTAssertEqual(end, TestFrames.so101.link(fromBase: target - start))
        XCTAssertEqual(end.x, 0.03, accuracy: 1e-12)
        XCTAssertEqual(end.y, -0.04, accuracy: 1e-12)
        XCTAssertEqual(end.z, 0.04, accuracy: 1e-9)
    }

    // MARK: - Generated goes against a modelled arm

    /// The arm and the link as a going move meets them, enough to make a slow start, a pause or a late state look like
    /// a stall to rules that were careless about it. The server follows the command the link sent half a round trip
    /// before, once the start reaches it; while the link pauses the hold the server drops its lead and the arm stands,
    /// and it may also hold the arm still without saying so; the arm lags the server's setpoint with a time constant
    /// and a top speed; states are measured about 5.5 times a second and arrive half a round trip later, the first one
    /// after the tap possibly late; the rules take a state's age from its arrival, as the app does, so a position
    /// always looks newer than it is.
    private struct ModelledArm {
        var oneWay: Double
        var tau: Double
        /// The link sends its start this long after the tap (a start held back), pausing the hold until then.
        var startSentAt = 0.0
        /// The link pauses the hold (a re-sent start) over this span of the rules' clock.
        var pause: ClosedRange<Double>?
        /// The first state after the tap arrives this much later than the others would.
        var late = 0.0
        /// No state is measured from this time on.
        var silentFrom = Double.infinity
        /// The server holds the arm where it is over this span of the rules' clock without saying so: a start it took
        /// late, or a freeze. Afterwards it follows the command again.
        var frozen: ClosedRange<Double>?
        /// When the first state after the tap is measured, and how old the tap's own state was at the tap.
        var phase = 0.0
        var tapAge = 0.0
        /// A wall in the arm's way, if any.
        var block: ((SIMD3<Double>) -> SIMD3<Double>)?
    }

    private struct Outcome {
        var end: End
        var at: TimeInterval
        var corrections: Int
        /// When the newest state the rules had at the end arrived.
        var lastArrival: TimeInterval
        /// The lowest commanded height while the level leg ran, if it began.
        var lowestLevel: Double?
    }

    private func simulate(
        from start: SIMD3<Double>, to target: SIMD3<Double>, _ model: ModelledArm, _ label: String,
        limits: GoToLimits? = nil
    ) -> Outcome {
        let limits = limits ?? self.limits
        var move = GoMove(frames: TestFrames.so101, start: start, target: target, limits: limits, at: 0)
        let period = 1 / 5.5, substeps = 4
        var sent: [SIMD3<Double>] = []
        var arm = start, setpoint = start
        var newest = (pinch: start, arrived: -model.tapAge)
        var inFlight: [(pinch: SIMD3<Double>, arrives: Double)] = []
        var nextMeasure = model.phase
        var measured = 0
        var corrections = 0
        var turned = false
        var lowestLevel: Double?
        var previous: SIMD3<Double>?
        var i = 0
        while true {
            let now = Double(i) * step
            // The server and the arm, from the last gate call to this one.
            if i > 0 {
                for k in 1...substeps {
                    let t = now - step + step * Double(k) / Double(substeps)
                    let atServer = t - model.oneWay
                    let following = atServer >= model.startSentAt && !(model.pause?.contains(atServer) ?? false)
                    if model.frozen?.contains(t) ?? false {
                        setpoint = arm
                    } else if following {
                        setpoint = sent[min(sent.count - 1, max(0, Int(atServer / step)))]
                    } else if model.pause?.contains(atServer) ?? false {
                        setpoint = arm
                    }
                    var velocity = (setpoint - arm) / model.tau
                    let speed = simd_length(velocity)
                    if speed > 0.13 { velocity *= 0.13 / speed }
                    arm += velocity * (step / Double(substeps))
                    if let block = model.block { arm = block(arm) }
                    if t >= nextMeasure {
                        if t < model.silentFrom {
                            let extra = measured == 0 ? model.late : 0
                            inFlight.append((arm, t + model.oneWay + extra))
                        }
                        measured += 1
                        nextMeasure += period
                    }
                }
            }
            for state in inFlight where state.arrives <= now && state.arrives > newest.arrived {
                newest = (state.pinch, state.arrives)
            }
            inFlight.removeAll { $0.arrives <= now }
            let paused = now < model.startSentAt || (model.pause?.contains(now) ?? false)
            let left = move.correctionsLeft
            let fix = ArmFix(pinch: newest.pinch, ageS: now - newest.arrived, holdPaused: paused)
            let verdict = move.observe(fix, at: now)
            if move.correctionsLeft < left { corrections += 1 }
            if move.stage != .vertical && move.stage != .correcting(.vertical) { turned = true }
            let offset = move.linkOffset(at: now)
            if let previous {
                XCTAssertLessThanOrEqual(
                    simd_distance(offset, previous), limits.speedMps * step + 1e-9, "\(label), at \(now)")
            }
            previous = offset
            if !turned { XCTAssertEqual(SIMD2(offset.x, offset.y), .zero, "nothing level before the corner, \(label)") }
            let height = move.commanded(at: now).z
            if move.stage == .level { lowestLevel = min(lowestLevel ?? height, height) }
            let floor = heightFloor(move)
            XCTAssertGreaterThanOrEqual(height, floor, "no command below the travel height, \(move.stage), \(label)")
            XCTAssertGreaterThanOrEqual(
                move.commanded(at: .infinity).z, floor, "no leg ends below the travel height, \(move.stage), \(label)")
            sent.append(move.commanded(at: now))
            let end: End?
            if let verdict {
                end = .verdict(verdict)
            } else if now >= move.deadline {
                end = .timeIsUp
            } else {
                end = now > 60 ? .goingOn : nil
            }
            if let end {
                return Outcome(
                    end: end, at: now, corrections: corrections, lastArrival: newest.arrived, lowestLevel: lowestLevel)
            }
            i += 1
        }
    }

    /// A random tap's start and target in the SO-101's box: every third one starts 9 to 12 mm off the travel height,
    /// the short vertical leg where a slow start is most easily taken for a stall.
    private func randomGo(_ random: inout SplitMix64, index: Int) -> (start: SIMD3<Double>, target: SIMD3<Double>) {
        let target = SIMD3(random.uniform(-0.05, 0.10), random.uniform(-0.25, -0.10), travel)
        let z: Double
        if index % 3 == 0 {
            z = travel + (random.chance(0.5) ? 1 : -1) * random.uniform(0.009, 0.012)
        } else {
            z = random.uniform(0.05, 0.15)
        }
        return (SIMD3(random.uniform(-0.05, 0.10), random.uniform(-0.25, -0.10), z), target)
    }

    private func randomModel(_ random: inout SplitMix64) -> ModelledArm {
        let taus = [0.1, 0.3, 0.5, 0.8]
        var model = ModelledArm(
            oneWay: random.uniform(0.01, 0.19), tau: taus[Int(random.next() % UInt64(taus.count))])
        model.startSentAt = [0, 0, 0.3, 0.8][Int(random.next() % 4)]
        if random.chance(0.25) {
            let from = random.uniform(1, 3)
            model.pause = from...(from + random.uniform(0.3, 1.0))
        }
        model.late = random.chance(0.5) ? random.uniform(0.1, 0.3) : 0
        model.phase = random.uniform(0, 1 / 5.5)
        model.tapAge = random.uniform(0, 0.18)
        return model
    }

    /// Nothing in the way: every go arrives, none takes a correction, whatever the lag, the round trip (under the
    /// 0.4 s slow-link block), a start held back, a re-sent start or a late state.
    func testGeneratedGoesThatNothingBlocksArriveWithoutACorrection() {
        var random = SplitMix64(seed: 0x60_30E5)
        var count = 0
        for index in 0..<150 {
            let go = randomGo(&random, index: index)
            let model = randomModel(&random)
            guard simd_distance(go.start, go.target) > limits.arriveToleranceM else { continue }
            let outcome = simulate(from: go.start, to: go.target, model, "go \(index)")
            XCTAssertEqual(outcome.end, .verdict(.arrived), "go \(index): \(model.tau) s lag, \(go)")
            XCTAssertEqual(outcome.corrections, 0, "go \(index): \(model.tau) s lag, \(go)")
            count += 1
        }
        XCTAssertGreaterThan(count, 140)
    }

    /// The conditions under which a slow start is most easily taken for a stall: a 9 to 12 mm vertical leg, an arm
    /// with a 0.8 s lag, a round trip of 0.30 to 0.38 s and a late state after the tap. With the profile's grace and
    /// with none, no go takes a correction and every one arrives.
    func testGeneratedSlowStartsOnShortLegsAreNotStalls() {
        for grace in [limits.startGraceS, 0] {
            var random = SplitMix64(seed: 0x51_0E57)
            var numbers = limits
            numbers.startGraceS = grace
            for index in 0..<100 {
                let leg = random.uniform(0.009, 0.012) * (random.chance(0.5) ? 1 : -1)
                let start = SIMD3(random.uniform(-0.05, 0.10), random.uniform(-0.25, -0.10), travel + leg)
                let target = SIMD3(random.uniform(-0.05, 0.10), random.uniform(-0.25, -0.10), travel)
                var model = ModelledArm(oneWay: random.uniform(0.15, 0.19), tau: 0.8)
                model.late = random.uniform(0.1, 0.3)
                model.phase = random.uniform(0, 1 / 5.5)
                model.tapAge = random.uniform(0, 0.18)
                let outcome = simulate(from: start, to: target, model, "slow \(index), grace \(grace)", limits: numbers)
                XCTAssertEqual(outcome.end, .verdict(.arrived), "slow \(index), grace \(grace)")
                XCTAssertEqual(outcome.corrections, 0, "slow \(index), grace \(grace)")
            }
        }
    }

    /// An arm blocked short on the level leg, 12 mm to 5 cm before the target: it stops short, never "time is up".
    func testGeneratedGoesBlockedShortStopShort() {
        var random = SplitMix64(seed: 0xB10C_ED)
        var count = 0
        for index in 0..<45 {
            let go = randomGo(&random, index: index)
            var model = randomModel(&random)
            let corner = SIMD3(go.start.x, go.start.y, travel)
            guard simd_distance(corner, go.target) > 0.06 else { continue }
            let across = simd_normalize(go.target - corner)
            let wall = simd_dot(go.target - corner, across) - [0.012, 0.025, 0.05][index % 3]
            model.block = { point in
                let along = simd_dot(point - corner, across)
                return along <= wall ? point : point - across * (along - wall)
            }
            let outcome = simulate(from: go.start, to: go.target, model, "blocked \(index)")
            XCTAssertEqual(outcome.end, .verdict(.stoppedShort), "blocked \(index): \(model.tau) s lag, \(go)")
            count += 1
        }
        XCTAssertGreaterThan(count, 15)
    }

    /// Something under the whole way, 1 to 5 cm above the travel height, below a start above it: the arm can never
    /// come within the tolerance of the target, and no command, a correction at the end included, goes below the
    /// travel height to push it there (`simulate` checks every call). The move stops short.
    func testGeneratedGoesOntoAnObstacleAboveTheTravelHeightStopShort() {
        var random = SplitMix64(seed: 0x0B_57AC)
        for index in 0..<60 {
            var go = randomGo(&random, index: index)
            var model = randomModel(&random)
            let short = random.uniform(0.010, 0.050)
            go.start.z = travel + random.uniform(short + 0.002, 0.06)
            let surface = travel + short
            model.block = { SIMD3($0.x, $0.y, max($0.z, surface)) }
            let outcome = simulate(from: go.start, to: go.target, model, "obstacle \(index)")
            XCTAssertEqual(outcome.end, .verdict(.stoppedShort), "obstacle \(index): \(short) m up, \(model.tau) s lag")
        }
    }

    /// Positions stop arriving part way: the go ends "no arm data" no later than one gate step after the newest state
    /// is 2 s old, unless it arrived first.
    func testGeneratedGoesWhosePositionsStopEndWithNoArmData() {
        var random = SplitMix64(seed: 0x5_11E7)
        for index in 0..<30 {
            let go = randomGo(&random, index: index)
            var model = randomModel(&random)
            model.silentFrom = random.uniform(0.5, 1.5)
            guard simd_distance(go.start, go.target) > 0.05 else { continue }
            let outcome = simulate(from: go.start, to: go.target, model, "silent \(index)")
            if outcome.end == .verdict(.arrived) { continue }
            XCTAssertEqual(outcome.end, .verdict(.noArmData), "silent \(index)")
            XCTAssertLessThanOrEqual(
                outcome.at, outcome.lastArrival + limits.armDataTimeoutS + step + 1e-9, "silent \(index)")
        }
    }

    /// A server that takes the start later than the grace, or holds the arm still for a while without saying so: the
    /// arm stands above or below the travel height for longer than any rule expects, and still no command after the
    /// first leg, a correction at the end included, runs below the travel height (`simulate` checks every call),
    /// whatever the move then ends with.
    func testGeneratedGoesWithAnArmHeldStillNeverRunTheLevelLegLow() {
        var random = SplitMix64(seed: 0xF2_0237)
        var level = 0
        for index in 0..<150 {
            let go = randomGo(&random, index: index)
            var model = randomModel(&random)
            if index % 2 == 0 {
                model.frozen = 0...random.uniform(1.5, 3.0)
            } else {
                let from = random.uniform(0, 3)
                model.frozen = from...(from + random.uniform(0.5, 2.5))
            }
            guard simd_distance(go.start, go.target) > limits.arriveToleranceM else { continue }
            let outcome = simulate(from: go.start, to: go.target, model, "held still \(index)")
            XCTAssertNotEqual(outcome.end, .goingOn, "held still \(index)")
            if outcome.lowestLevel != nil { level += 1 }
        }
        XCTAssertGreaterThan(level, 100, "most of them reached the level leg")
    }

    /// A server that froze for the first 5 s without saying so, on a 2.5 cm way down: the level leg starts once the
    /// command reaches the corner and runs at the travel height, with no correction on the way down; the arm, still
    /// standing when the command has waited at the target for the settle time, has stopped short.
    func testAServerFrozenOnAShortWayDownNeverLowersTheLevelLeg() throws {
        var model = ModelledArm(oneWay: 0.05, tau: 0.3)
        model.frozen = 0...5
        let outcome = simulate(
            from: SIMD3(0.0, -0.20, travel + 0.025), to: SIMD3(0.06, -0.15, travel), model, "frozen for 5 s")
        XCTAssertEqual(try XCTUnwrap(outcome.lowestLevel), travel, "the level leg at the travel height, exactly")
        XCTAssertEqual(outcome.corrections, 0)
        XCTAssertEqual(outcome.end, .verdict(.stoppedShort))
    }

    /// A start the server took 2.6 s late, nothing else wrong, on a 2.5 cm way down: the level leg runs at the travel
    /// height, and the arm arrives without a correction once it moves.
    func testAStartTakenLateOnAShortWayDownNeverLowersTheLevelLeg() throws {
        var model = ModelledArm(oneWay: 0.05, tau: 0.3)
        model.frozen = 0...(model.oneWay + 2.6)
        let outcome = simulate(
            from: SIMD3(0.0, -0.20, travel + 0.025), to: SIMD3(0.06, -0.15, travel), model, "start taken 2.6 s late")
        XCTAssertEqual(try XCTUnwrap(outcome.lowestLevel), travel, "the level leg at the travel height, exactly")
        XCTAssertEqual(outcome.corrections, 0)
        XCTAssertEqual(outcome.end, .verdict(.arrived))
    }
}
