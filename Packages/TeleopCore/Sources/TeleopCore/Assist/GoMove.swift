import Foundation
import simd

/// One going move: from the pinch point measured at the tap, straight up or down to the travel height, then level to
/// the tapped point, at the profile's speed. Pure: time is passed in, on the input rules' clock.
///
/// The commanded pinch point moves along the current leg and waits at its end. A leg is over by time, never by
/// comparing computed positions: once the time since it began is at least its length over the speed, the command is
/// the leg's end exactly. A point computed at the full share can miss the leg's end in the last bit (a leg whose ends
/// have opposite signs, for one), and a leg judged by equality would then never end.
///
/// The next leg begins only on measured positions: once the command has reached the corner, the level leg starts when a
/// fresh fix is no lower than the travel height less the tolerance, so the jaws never sweep low across the table while
/// the arm lags. Above the travel height is safe: an arm coming down from above starts its level leg at once and goes
/// on descending as it moves. A correction on the way up or down only ever raises the command, so the level leg's
/// command is the travel height plus that raise, never lower, and a correction at the end never takes it lower either:
/// once the command has reached the travel height, no commanded point is below it. The move ends on measured positions
/// too: the server drops the remaining lead at a stop, so the stop must wait for the arm, never for the command.
struct GoMove: Equatable, Sendable {
    enum Leg: Equatable, Sendable { case vertical, level }

    enum Stage: Equatable, Sendable {
        case vertical
        case level
        /// Walking a correction of that leg.
        case correcting(Leg)
    }

    /// Why the move is over. The deadline is not here: the input rules judge it in their gate.
    enum Verdict: Equatable, Sendable { case arrived, stoppedShort, noArmData }

    /// A measured position older than this says nothing about now (the feedback monitor's own number).
    static let freshS = Double(FeedbackMonitor.freshStateMs) / 1000
    /// Fresh measured points within this of one another count as standing still, and an arm this far from where it
    /// started has been seen to move (the monitor's blocked rule's number).
    static let settleMoveM = FeedbackMonitor.blockedMovedMeters

    /// The measured pinch point at the tap, robot base frame, metres.
    let start: SIMD3<Double>
    /// The tapped point at the travel height. Corrections never move it, and arrival is judged against it.
    let target: SIMD3<Double>
    let limits: GoToLimits
    /// The tap, on the input rules' clock.
    let startedAt: TimeInterval
    private(set) var stage: Stage
    private(set) var correctionsLeft: Int
    /// The input rules end the move here.
    private(set) var deadline: TimeInterval
    /// How far vertical corrections raised the commanded height so that the measured pinch point holds the travel
    /// height. Never negative: the level leg's command is the travel height plus it, and a correction at the end never
    /// goes below that. The target never moves.
    private var heightAim = 0.0
    private var legFrom: SIMD3<Double>
    private var legTo: SIMD3<Double>
    private var legStartedAt: TimeInterval
    /// The latest call whose fix said the link was pausing the hold. Nothing measured before it counts for a stall.
    private var pausedUntil = -TimeInterval.infinity
    /// A fresh fix has shown the arm `settleMoveM` or more from `start`: the start's grace is over.
    private var seenMoving = false
    /// The first of a run of fresh fixes within `settleMoveM` of it, and when it was measured.
    private var settle: Settle?

    private struct Settle: Equatable, Sendable {
        var anchor: SIMD3<Double>
        var measuredAt: TimeInterval
    }

    /// - start: the measured pinch point at the tap. - target: the tapped point at the travel height. - now: the tap.
    init(start: SIMD3<Double>, target: SIMD3<Double>, limits: GoToLimits, at now: TimeInterval) {
        self.start = start
        self.target = target
        self.limits = limits
        startedAt = now
        stage = .vertical
        correctionsLeft = limits.corrections
        legFrom = start
        legTo = SIMD3(start.x, start.y, target.z)
        legStartedAt = now
        let path = abs(target.z - start.z) + simd_length(SIMD2(target.x - start.x, target.y - start.y))
        deadline = now + path / limits.speedMps * limits.timeFactor + limits.allowanceS
    }

    /// When the current leg's command reaches its end. At and after this moment `commanded` is the leg's end exactly.
    private var legEndsAt: TimeInterval { legStartedAt + simd_length(legTo - legFrom) / limits.speedMps }

    private var isVerticalStage: Bool { stage == .vertical || stage == .correcting(.vertical) }

    /// The commanded pinch point at `time`: along the current leg at `speedMps`, then its end, exactly.
    func commanded(at time: TimeInterval) -> SIMD3<Double> {
        let length = simd_length(legTo - legFrom)
        // Over by time; no computed point is compared with the leg's end.
        guard length > 0, time < legEndsAt else { return legTo }
        let share = max(0, time - legStartedAt) * limits.speedMps / length
        return legFrom + (legTo - legFrom) * share
    }

    /// What the link sends: the whole way asked for since the start, in the frame `TeleopLink.poseUpdate` takes. A
    /// translation moves the gripper link and the pinch point alike, so a pinch-point difference is the gripper-link
    /// one.
    func linkOffset(at time: TimeInterval) -> SIMD3<Double> {
        OperatorFrame.link(fromBase: commanded(at: time) - start)
    }

    /// Judges the newest measured arm at `now`; nil while the move goes on. Changes legs and aims as it goes.
    mutating func observe(_ fix: ArmFix?, at now: TimeInterval) -> Verdict? {
        guard let fix, fix.ageS <= limits.armDataTimeoutS else { return .noArmData }
        if fix.holdPaused { pausedUntil = now }
        // A stale fix says nothing either way: no arrival, no corner, no settle.
        guard fix.ageS <= Self.freshS else {
            settle = nil
            return nil
        }
        let measuredAt = now - fix.ageS
        if simd_distance(fix.pinch, start) >= Self.settleMoveM { seenMoving = true }
        if simd_distance(fix.pinch, target) <= limits.arriveToleranceM { return .arrived }
        let atLegEnd = now >= legEndsAt
        // Only a measured point lower than the travel height less the tolerance holds the corner: sweeping low is what
        // this guards against, and an arm above the travel height comes down towards it along the level leg.
        if isVerticalStage, atLegEnd, target.z - fix.pinch.z <= limits.arriveToleranceM {
            begin(.level, to: target + SIMD3(0, 0, heightAim), at: now)
            return nil
        }
        // A stall is judged only from positions measured after all of these: the command reached the leg's end, the
        // last pause ended, and the start's grace is over, counted from the later of the start and that pause's end.
        // A late start, a pause, or a start the link held back and the server then took late is never taken for a
        // stall, and the fix taken at the tap never anchors one.
        let graceEnds = seenMoving ? -TimeInterval.infinity : max(startedAt, pausedUntil) + limits.startGraceS
        let judgedFrom = max(legEndsAt, pausedUntil, graceEnds)
        guard atLegEnd, !fix.holdPaused, measuredAt > judgedFrom else {
            settle = nil
            return nil
        }
        if let settle, simd_distance(fix.pinch, settle.anchor) <= Self.settleMoveM {
            guard measuredAt - settle.measuredAt >= limits.settleS else { return nil }
        } else {
            settle = Settle(anchor: fix.pinch, measuredAt: measuredAt)
            return nil
        }
        // Settled short of where this leg goes.
        if isVerticalStage {
            // Settled below the travel height less the tolerance, since anything higher turned the corner above, so
            // the missing height is positive and a correction here only ever raises the command. Only how far the
            // command goes to hold the travel height changes; the target stays where it was tapped.
            let missing = target.z - fix.pinch.z
            guard correctionsLeft > 0, missing <= limits.correctionReachM else { return .stoppedShort }
            correctionsLeft -= 1
            heightAim += missing
            deadline += missing / limits.speedMps * limits.timeFactor + limits.settleS
            begin(.correcting(.vertical), to: legTo + SIMD3(0, 0, missing), at: now)
        } else {
            let remainder = target - fix.pinch
            guard correctionsLeft > 0, simd_length(remainder) <= limits.correctionReachM else { return .stoppedShort }
            correctionsLeft -= 1
            deadline += simd_length(remainder) / limits.speedMps * limits.timeFactor + limits.settleS
            // The end moves across by all that is missing, and up if the jaws hang low, but never below the level
            // leg's own height: an arm resting on something above the travel height would otherwise have the command
            // pressed down into it at the target. Such an arm settles short again and stops short.
            var end = legTo + remainder
            end.z = max(end.z, target.z + heightAim)
            begin(.correcting(.level), to: end, at: now)
        }
        return nil
    }

    /// Starts a leg from where the command is now, so the commanded point never jumps.
    private mutating func begin(_ next: Stage, to end: SIMD3<Double>, at now: TimeInterval) {
        legFrom = commanded(at: now)
        legTo = end
        legStartedAt = now
        stage = next
        settle = nil
    }
}
