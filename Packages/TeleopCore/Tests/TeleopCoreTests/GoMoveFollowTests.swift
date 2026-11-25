import XCTest
import simd
@testable import TeleopCore

/// A going move that follows the measured offset (pinch point less gripper link) of a server that reports the pinch
/// point: half of each fresh reading's change is taken off the link command, the command starts at half speed and
/// slows where the offset swings more than a quarter of the distance the link moves, a reading off the leg ahead or
/// without the pinch point ends the move stopped short, the gripper link asked for stays inside the box less the tap's
/// offset, a pace measured after a leg's command has reached its end never takes the command back along that leg, the
/// command waits while the newest reading is stale, and without a measured offset at the tap nothing changes. Against
/// an arm whose pinch point turns with its posture, moves arrive, and a move the readings show cannot get there stops
/// short by itself.
final class GoMoveFollowTests: XCTestCase {
    /// The SO-101 simulator's go numbers (the core tests cannot reach `RobotProfile`).
    private let limits = GoToLimits(
        travelHeightM: 0.05, speedMps: 0.04, arriveToleranceM: 0.008, corrections: 2, correctionReachM: 0.03,
        settleS: 0.6, timeFactor: 1.5, allowanceS: 3, armDataTimeoutS: 2, startGraceS: 1.5)
    /// The pinch point's travel height in the base frame: the profile's table, a `Float`, plus the travel height.
    private let travel = Double(Float(0.04)) + 0.05
    /// A pinch point above the travel height, the tapped point beside it at the travel height, and an offset like the
    /// simulator's at its reset pose.
    private var start: SIMD3<Double> { SIMD3(0.02, -0.20, travel + 0.03) }
    private var target: SIMD3<Double> { SIMD3(0.05, -0.20, travel) }
    private let tapOffset = SIMD3(0.0125, -0.061, -0.072)

    private func reading(gripper: SIMD3<Double>, offset: SIMD3<Double>, age: Double = 0.1, reported: Bool = true)
        -> ArmFix
    {
        ArmFix(pinch: gripper + offset, ageS: age, holdPaused: false, gripper: gripper, pinchReported: reported)
    }

    func testWithoutAMeasuredOffsetNothingChanges() {
        var plain = GoMove(start: start, target: target, limits: limits, at: 0)
        var told = GoMove(start: start, target: target, limits: limits, at: 0, offset: nil)
        XCTAssertEqual(plain.deadline, told.deadline)
        for i in 0..<300 {
            let now = Double(i) / 30
            let pinch = plain.commanded(at: now - 0.2)
            let estimate = ArmFix(pinch: pinch, ageS: 0.1, holdPaused: false, gripper: pinch - tapOffset)
            XCTAssertEqual(
                plain.observe(ArmFix(pinch: pinch, ageS: 0.1, holdPaused: false), at: now),
                told.observe(estimate, at: now))
            XCTAssertEqual(plain.linkOffset(at: now), told.linkOffset(at: now))
        }
    }

    func testAFollowingMoveStartsAtHalfSpeedAndHasTheTimeForIt() {
        let plain = GoMove(start: start, target: target, limits: limits, at: 0)
        let following = GoMove(start: start, target: target, limits: limits, at: 0, offset: tapOffset)
        XCTAssertEqual(simd_distance(plain.commanded(at: 0.5), start), 0.02, accuracy: 1e-12)
        XCTAssertEqual(simd_distance(following.commanded(at: 0.5), start), 0.01, accuracy: 1e-12)
        let path = 0.03 + 0.03
        XCTAssertEqual(following.deadline - plain.deadline, path / 0.04 * limits.timeFactor, accuracy: 1e-9)
    }

    func testEachFreshReadingTakesHalfTheOffsetsChangeOffTheLinkCommand() {
        var move = GoMove(start: start, target: target, limits: limits, at: 0, offset: tapOffset)
        let gripper = start - tapOffset + SIMD3(0, 0, -0.001)
        let change = SIMD3(0.0002, 0, 0.0004)
        XCTAssertNil(move.observe(reading(gripper: gripper, offset: tapOffset + change), at: 0.2))
        let planned = OperatorFrame.link(fromBase: move.commanded(at: 0.2) - start)
        let sent = move.linkOffset(at: 0.2)
        XCTAssertEqual(simd_distance(sent - planned, OperatorFrame.link(fromBase: -change * 0.5)), 0, accuracy: 1e-12)
        // The same reading seen again changes nothing.
        XCTAssertNil(move.observe(reading(gripper: gripper, offset: tapOffset + change, age: 0.2), at: 0.3))
        XCTAssertEqual(
            simd_distance(
                move.linkOffset(at: 0.3) - OperatorFrame.link(fromBase: move.commanded(at: 0.3) - start), sent - planned
            ),
            0, accuracy: 1e-12)
    }

    func testAnOffsetThatSwingsMoreThanTheLinkMovesSlowsTheCommand() {
        var move = GoMove(start: start, target: target, limits: limits, at: 0, offset: tapOffset)
        let gripper0 = start - tapOffset
        XCTAssertNil(move.observe(reading(gripper: gripper0, offset: tapOffset), at: 0.1))
        let before = move.deadline
        // 3 mm of link travel while the offset turns by 7.5 mm: a swing of 2.5, so the slowest pace, 0.15.
        let gripper1 = gripper0 + SIMD3(0, 0, -0.003)
        let offset1 = tapOffset + SIMD3(0.0075, 0, 0)
        XCTAssertNil(move.observe(reading(gripper: gripper1, offset: offset1), at: 0.4))
        let stepped = simd_distance(move.commanded(at: 0.5), move.commanded(at: 0.4))
        XCTAssertEqual(stepped, 0.04 * 0.15 * 0.1, accuracy: 1e-9)
        XCTAssertGreaterThan(move.deadline, before)
    }

    /// A reading that changes the pace, slower or faster, leaves the command where it is at that instant: only how fast
    /// it goes on changes. What the link sends changes then by the reading's half of the offset's change and nothing
    /// more.
    func testAChangeOfPaceLeavesTheCommandWhereItIs() {
        let gripper0 = start - tapOffset
        // 3 mm of link travel while the offset turns by 7.5 mm, then by 0.2 mm: from half speed to 0.15 of it, and to all
        // of it.
        let paces = [
            "slower": (offset: SIMD3(0.0075, 0, 0), share: 0.15),
            "faster": (offset: SIMD3(0.0002, 0, 0), share: 1.0),
        ]
        for (name, pace) in paces {
            var move = GoMove(start: start, target: target, limits: limits, at: 0, offset: tapOffset)
            XCTAssertNil(move.observe(reading(gripper: gripper0, offset: tapOffset), at: 0.1), name)
            let commanded = move.commanded(at: 0.4)
            let sent = move.linkOffset(at: 0.4)
            let gripper1 = gripper0 + SIMD3(0, 0, -0.003)
            XCTAssertNil(move.observe(reading(gripper: gripper1, offset: tapOffset + pace.offset), at: 0.4), name)
            let stepped = simd_distance(move.commanded(at: 0.5), move.commanded(at: 0.4))
            XCTAssertEqual(stepped, 0.04 * pace.share * 0.1, accuracy: 1e-9, "\(name): the pace changed")
            XCTAssertEqual(simd_distance(move.commanded(at: 0.4), commanded), 0, accuracy: 1e-12, name)
            XCTAssertEqual(
                simd_distance(move.linkOffset(at: 0.4) - sent, OperatorFrame.link(fromBase: -pace.offset * 0.5)), 0,
                accuracy: 1e-12, name)
        }
    }

    func testAReadingOffTheLegAheadEndsTheMoveStoppedShort() {
        var near = GoMove(start: start, target: target, limits: limits, at: 0, offset: tapOffset)
        var far = near
        let aside = { (d: Double) in self.start - self.tapOffset + SIMD3(0, d, 0) }
        XCTAssertNil(near.observe(reading(gripper: aside(0.019), offset: tapOffset), at: 0.2))
        XCTAssertEqual(far.observe(reading(gripper: aside(0.021), offset: tapOffset), at: 0.2), .stoppedShort)
    }

    func testAReadingWithoutThePinchPointEndsTheMoveAndAStaleOneDoesNot() {
        var move = GoMove(start: start, target: target, limits: limits, at: 0, offset: tapOffset)
        let gripper = start - tapOffset
        XCTAssertNil(move.observe(reading(gripper: gripper, offset: tapOffset), at: 0.2))
        XCTAssertNil(move.observe(reading(gripper: gripper, offset: tapOffset, age: 0.5, reported: false), at: 0.4))
        XCTAssertEqual(
            move.observe(reading(gripper: gripper, offset: tapOffset, age: 0.1, reported: false), at: 0.5),
            .stoppedShort)
    }

    func testTheGripperLinkAskedForStaysInsideTheBoxLessTheTapsOffset() {
        let low = target - SIMD3(0.04, 0.04, 0.0), high = start + SIMD3(0.04, 0.04, 0.01)
        var move = GoMove(
            start: start, target: target, limits: limits, at: 0, boxLow: low, boxHigh: high, offset: tapOffset)
        let gripper = start - tapOffset
        // An offset that grew by 9 cm sideways would send the link far outside the box.
        _ = move.observe(reading(gripper: gripper, offset: tapOffset + SIMD3(0, 0.09, 0)), at: 0.2)
        let link = OperatorFrame.base(fromLink: move.linkOffset(at: 0.3)) + (start - tapOffset)
        XCTAssertTrue(all(link .>= low - tapOffset - 1e-12) && all(link .<= high - tapOffset + 1e-12), "\(link)")
    }

    // MARK: - A leg that has ended, a stale reading

    /// A level move from the travel height, with the pinch point straight below the gripper link.
    private let levelStart = SIMD3(0.0, -0.2, 0.09)
    private let levelTarget = SIMD3(0.05, -0.2, 0.09)
    private let downOffset = SIMD3(0.0, 0.0, -0.08)

    private func reading(pinch: SIMD3<Double>, offset: SIMD3<Double>, age: Double = 0.1) -> ArmFix {
        ArmFix(pinch: pinch, ageS: age, holdPaused: false, gripper: pinch - offset, pinchReported: true)
    }

    /// A move that starts at the travel height turns its corner at the first fresh reading and goes level at half
    /// speed, so the level leg's command reaches the target 2.5 s later, at 2.6 s.
    private func levelMove() -> GoMove {
        var move = GoMove(start: levelStart, target: levelTarget, limits: limits, at: 0, offset: downOffset)
        XCTAssertNil(move.observe(reading(pinch: levelStart, offset: downOffset), at: 0.1))
        XCTAssertEqual(move.stage, .level)
        return move
    }

    /// The jaws are still 20 mm short when the level leg's command has reached its end, and the offset has swung by
    /// most of the gripper link's travel: the slower pace is for a later leg, and the command stays at the end.
    func testAPaceMeasuredAfterTheLegEndedNeverTakesTheCommandBack() {
        var move = levelMove()
        XCTAssertEqual(move.commanded(at: 3.0), levelTarget)
        let pinch = SIMD3(0.03, -0.2, 0.09)
        XCTAssertNil(move.observe(reading(pinch: pinch, offset: SIMD3(0, 0, -0.015)), at: 3.0))
        XCTAssertEqual(move.commanded(at: 3.0), levelTarget, "the command went back along an ended leg")
        XCTAssertEqual(move.commanded(at: 3.1), levelTarget)
    }

    /// Readings older than the fresh limit: the command waits where it is, and once a fresh reading comes it goes on
    /// from there along the leg, with the time limit grown by the wait.
    func testAFollowingMoveWaitsWhileItsNewestReadingIsStale() {
        var move = levelMove()
        XCTAssertNil(move.observe(reading(pinch: move.commanded(at: 0.8), offset: downOffset), at: 1.0))
        let before = move.deadline
        XCTAssertNil(move.observe(reading(pinch: move.commanded(at: 0.8), offset: downOffset, age: 0.5), at: 1.4))
        let held = move.commanded(at: 1.4)
        XCTAssertEqual(move.commanded(at: 2.4), held)
        XCTAssertNil(move.observe(reading(pinch: move.commanded(at: 0.8), offset: downOffset, age: 1.5), at: 2.4))
        XCTAssertEqual(move.commanded(at: 2.4), held)
        XCTAssertNil(move.observe(reading(pinch: held, offset: downOffset), at: 2.5))
        XCTAssertEqual(move.deadline, before + 1.1, accuracy: 1e-9)
        XCTAssertEqual(move.commanded(at: 2.5), held)
        XCTAssertGreaterThan(simd_distance(move.commanded(at: 3.0), held), 0)
        XCTAssertLessThanOrEqual(simd_distance(move.commanded(at: 3.0), held), 0.5 * 0.04 + 1e-9)
    }

    /// A move that follows nothing goes on while its reading is stale, as it always did.
    func testWithoutAMeasuredOffsetAStaleReadingDoesNotHoldTheCommand() {
        var move = GoMove(start: levelStart, target: levelTarget, limits: limits, at: 0)
        XCTAssertNil(move.observe(ArmFix(pinch: levelStart, ageS: 0.1, holdPaused: false), at: 0.1))
        let a = move.commanded(at: 0.5)
        XCTAssertNil(move.observe(ArmFix(pinch: levelStart, ageS: 0.5, holdPaused: false), at: 0.5))
        XCTAssertNotEqual(move.commanded(at: 0.9), a)
    }

    // MARK: - An arm whose pinch point turns with its posture

    /// A gripper whose pinch point turns with the arm's posture, with the numbers of the simulator's arm near its reset
    /// pose: the pinch point hangs `length` from the gripper link, tilted away from the pan axis by an angle from
    /// straight down that grows with the link's height and shrinks as the link goes out from the axis, and sits `aside`
    /// to the side. Its height rises with the link's at any place, so for a pinch height there is one link height.
    private struct TurningTool {
        var axis = SIMD2(0.0207, -0.0231)
        var length = 0.0945
        var aside = 0.01265
        var angle = 40.15 * Double.pi / 180
        var radius = 0.1183
        var height = 0.16
        var perRadius = -10.27
        var perHeight = 10.02

        func pinch(_ link: SIMD3<Double>) -> SIMD3<Double> {
            let out = SIMD2(link.x, link.y) - axis
            let r = simd_length(out)
            let away = out / r
            let side = SIMD2(-away.y, away.x)
            let tilt = angle + perRadius * (r - radius) + perHeight * (link.z - height)
            let across = away * (length * sin(tilt)) + side * aside
            return link + SIMD3(across.x, across.y, -length * cos(tilt))
        }

        /// The link whose pinch point is at `point`, found from `guess`; nil if none is found near it.
        func link(pinchAt point: SIMD3<Double>, from guess: SIMD3<Double>) -> SIMD3<Double>? {
            var link = guess
            for _ in 0..<40 {
                let miss = pinch(link) - point
                if simd_length(miss) < 1e-12 { return link }
                let columns = (0..<3).map { axis -> SIMD3<Double> in
                    var nudged = link
                    nudged[axis] += 1e-7
                    return (pinch(nudged) - pinch(link)) / 1e-7
                }
                link -= simd_double3x3(columns: (columns[0], columns[1], columns[2])).inverse * miss
            }
            return simd_length(pinch(link) - point) < 1e-9 ? link : nil
        }

        /// The link height over `place` whose pinch point is at `height`.
        func linkHeight(over place: SIMD2<Double>, pinchAt pinchHeight: Double) -> Double {
            var low = pinchHeight - length, high = pinchHeight + length
            for _ in 0..<60 {
                let middle = (low + high) / 2
                if pinch(SIMD3(place.x, place.y, middle)).z < pinchHeight { low = middle } else { high = middle }
            }
            return (low + high) / 2
        }
    }

    /// The simulator's gripper link after a reset.
    private let resetLink = SIMD3(0.020617, -0.141418, 0.159985)
    /// The SO-101 simulator's work box for the gripper link: the server's own, the profile's box for the pinch point
    /// less the profile's tool offset. The guide draws the box for the pinch point by the reading's measured offset, so
    /// the box a tap is judged against is this box plus the offset measured at the tap.
    private let linkLow = SIMD3(-0.059383, -0.221418, 0.079985)
    private let linkHigh = SIMD3(0.100617, -0.061418, 0.239985)

    private enum FollowEnd: Equatable {
        case verdict(GoMove.Verdict)
        case timeIsUp
        case goingOn
    }

    private struct FollowRun {
        var end: FollowEnd
        var at: TimeInterval
        var deadline: TimeInterval
        /// The lowest the pinch point went, and the lowest once the level leg had begun, if it began.
        var lowest: Double
        var lowestAfterCorner: Double?
    }

    /// A move from a link resting at `from` to `target`, against a server that applies each offset half a round trip
    /// after it was sent, from where the link stood at the tap, kept in its box; moves its setpoint at up to 0.257 m/s
    /// and the link after it with a 0.03 s lag; and reports the link and the pinch point every 0.2 s, each reading
    /// arriving 0.1 s after it was measured (`phase` of the first one). The gate runs 30 times a second. Every call
    /// checks that no commanded pinch point is outside the box, none below the travel height once the first leg is
    /// over, and that the gripper link asked for stays inside the server's box.
    private func follow(
        _ tool: TurningTool, from link: SIMD3<Double>, to target: SIMD3<Double>, phase: Double, _ label: String
    ) -> FollowRun {
        let step = 1.0 / 30, substeps = 4, oneWay = 0.1, period = 0.2
        let start = tool.pinch(link)
        let offset = start - link
        let low = linkLow + offset, high = linkHigh + offset
        var move = GoMove(
            start: start, target: target, limits: limits, at: 0, boxLow: low, boxHigh: high, offset: offset)
        var sent: [(at: TimeInterval, link: SIMD3<Double>)] = [(0, link)]
        var arm = link, setpoint = link
        var newest = (link: link, arrived: phase - period + oneWay)
        var inFlight: [(link: SIMD3<Double>, arrives: TimeInterval)] = []
        var nextMeasure = phase
        var turned = false
        var lowest = tool.pinch(link).z
        var lowestAfterCorner: Double?
        var i = 0
        while true {
            let now = Double(i) * step
            if i > 0 {
                for k in 1...substeps {
                    let dt = step / Double(substeps)
                    let t = now - step + dt * Double(k)
                    let asked = sent.last { $0.at <= t - oneWay }?.link ?? link
                    let goal = simd_clamp(asked, linkLow, linkHigh)
                    let gap = goal - setpoint
                    let reach = 0.257 * dt
                    setpoint += simd_length(gap) > reach ? simd_normalize(gap) * reach : gap
                    arm += (setpoint - arm) * min(1, dt / 0.03)
                    let height = tool.pinch(arm).z
                    lowest = min(lowest, height)
                    if turned { lowestAfterCorner = min(lowestAfterCorner ?? .infinity, height) }
                    if t >= nextMeasure {
                        inFlight.append((arm, t + oneWay))
                        nextMeasure += period
                    }
                }
            }
            for reading in inFlight where reading.arrives <= now { newest = (reading.link, reading.arrives) }
            inFlight.removeAll { $0.arrives <= now }
            let fix = ArmFix(
                pinch: tool.pinch(newest.link), ageS: now - newest.arrived + oneWay, holdPaused: false,
                gripper: newest.link, pinchReported: true)
            let verdict = move.observe(fix, at: now)
            if move.stage != .vertical { turned = true }
            let commanded = move.commanded(at: now)
            XCTAssertTrue(
                all(commanded .>= low - 1e-9) && all(commanded .<= high + 1e-9),
                "\(label): a commanded pinch point outside the box, \(commanded) at \(now)")
            let floor = move.stage == .vertical ? min(start.z, target.z) : target.z
            XCTAssertGreaterThanOrEqual(
                commanded.z, floor - 1e-12, "\(label): commanded below the travel height, \(move.stage) at \(now)")
            let asked = link + OperatorFrame.base(fromLink: move.linkOffset(at: now))
            XCTAssertTrue(
                all(asked .>= linkLow - 1e-9) && all(asked .<= linkHigh + 1e-9),
                "\(label): the gripper link asked for outside the server's box, \(asked) at \(now)")
            sent.append((now, asked))
            let end: FollowEnd?
            if let verdict {
                end = .verdict(verdict)
            } else if now >= move.deadline {
                end = .timeIsUp
            } else {
                end = now > 60 ? .goingOn : nil
            }
            if let end {
                return FollowRun(
                    end: end, at: now, deadline: move.deadline, lowest: lowest, lowestAfterCorner: lowestAfterCorner)
            }
            i += 1
        }
    }

    /// Whether `point` lies in the box a tap is judged against when the link stands at `link`: the server's box plus
    /// the offset measured there.
    private func inTapsBox(_ point: SIMD3<Double>, from link: SIMD3<Double>, _ tool: TurningTool) -> Bool {
        let offset = tool.pinch(link) - link
        return all(point .>= linkLow + offset) && all(point .<= linkHigh + offset)
    }

    /// With the numbers of the simulator's arm, moves from its reset pose, and from 8 to 14 cm above the table over
    /// places near it that the arm can reach at the travel height, to points the arm can bring its pinch point to at
    /// the travel height: every one arrives, the pinch point never goes more than 13 mm under the travel height once
    /// the level leg has begun, and no commanded point leaves the box or goes below the travel height after the first
    /// leg (`follow` checks every call).
    func testGeneratedMovesAgainstAPinchPointThatTurnsArrive() {
        let tool = TurningTool()
        XCTAssertLessThan(
            simd_distance(tool.pinch(resetLink), SIMD3(0.0332, -0.2024, 0.0878)), 0.0003,
            "the pinch point measured at the reset pose")
        var random = SplitMix64(seed: 0x70_0F01)
        var counts = (reset: 0, above: 0)
        for index in 0..<300 {
            // A place for the link in the server's box, at the height that brings the pinch point to the travel
            // height: a point the arm can reach.
            let place = SIMD2(random.uniform(linkLow.x, linkHigh.x), random.uniform(linkLow.y, linkHigh.y))
            let reached = tool.pinch(SIMD3(place.x, place.y, tool.linkHeight(over: place, pinchAt: travel)))
            let target = SIMD3(reached.x, reached.y, travel)
            let above = index % 2 == 1
            var from: SIMD3<Double>? = resetLink
            if above {
                // Straight above a place the arm can reach at the travel height, since the first leg goes straight
                // down to it.
                let near =
                    SIMD2(random.uniform(-0.03, 0.03), random.uniform(-0.03, 0.03)) + SIMD2(resetLink.x, resetLink.y)
                let corner = SIMD3(near.x, near.y, tool.linkHeight(over: near, pinchAt: travel))
                let below = tool.pinch(corner)
                let height = Double(Float(0.04)) + random.uniform(0.08, 0.14)
                from = tool.link(pinchAt: SIMD3(below.x, below.y, height), from: corner + SIMD3(0, 0, height - travel))
            }
            let phase = random.uniform(0, 0.2)
            guard let from, all(from .>= linkLow) && all(from .<= linkHigh), inTapsBox(target, from: from, tool),
                inTapsBox(tool.pinch(from), from: from, tool)
            else { continue }
            let label = "\(above ? "above" : "reset") \(index)"
            let run = follow(tool, from: from, to: target, phase: phase, label)
            XCTAssertEqual(run.end, .verdict(.arrived), "\(label): to \(target)")
            XCTAssertGreaterThanOrEqual(
                run.lowestAfterCorner ?? .infinity, travel - 0.013, "\(label): the pinch point dipped, to \(target)")
            if above { counts.above += 1 } else { counts.reset += 1 }
        }
        XCTAssertGreaterThan(counts.reset, 80)
        XCTAssertGreaterThan(counts.above, 80)
    }

    /// An arm folded so far that its pinch point goes outward when the gripper link goes inward (the angle changes
    /// 25 radians a metre out): a tap 3 to 7 cm inward of the jaws cannot be followed there. Each such move stops short
    /// by itself, well before its time limit, with the pinch point never more than 13 mm under the travel height and
    /// the gripper link asked for always inside the server's box.
    func testGeneratedTapsInwardOnAFoldedArmStopShortByThemselves() {
        var tool = TurningTool()
        tool.perRadius = -25
        XCTAssertLessThan(1 + tool.length * cos(tool.angle) * tool.perRadius, 0, "outward, the jaws go inward")
        var random = SplitMix64(seed: 0xF0_1DED)
        let start = tool.pinch(resetLink)
        let out = SIMD2(start.x, start.y) - tool.axis
        let away = out / simd_length(out), side = SIMD2(-away.y, away.x)
        var count = 0
        for index in 0..<120 {
            let place = SIMD2(start.x, start.y) - away * random.uniform(0.03, 0.07) + side * random.uniform(-0.03, 0.03)
            let target = SIMD3(place.x, place.y, travel)
            let phase = random.uniform(0, 0.2)
            guard inTapsBox(target, from: resetLink, tool) else { continue }
            let run = follow(tool, from: resetLink, to: target, phase: phase, "folded \(index)")
            XCTAssertEqual(run.end, .verdict(.stoppedShort), "folded \(index): to \(target)")
            XCTAssertLessThan(run.at, run.deadline, "folded \(index)")
            XCTAssertGreaterThanOrEqual(run.lowest, travel - 0.013, "folded \(index): the pinch point dipped")
            count += 1
        }
        XCTAssertGreaterThan(count, 80)
    }
}
