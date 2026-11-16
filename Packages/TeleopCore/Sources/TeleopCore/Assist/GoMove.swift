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
/// command is the travel height plus that raise, never lower, and a correction at the end may take back a raise but
/// never goes below the travel height: once the command has reached the travel height, no commanded point is below it.
/// In the same way no correction takes the command out of the work box the move was given, the box the tapped point
/// was judged against: every correction ends inside it, so a move that starts inside the box commands nothing outside
/// it. An arm held short near a face settles short again, and the move stops short.
/// The move ends on measured positions too: the server drops the remaining lead at a stop, so the stop must wait for
/// the arm, never for the command.
///
/// The server moves the gripper link, and the pinch point is a point fixed to the gripper, which tilts and turns with
/// the arm's posture: a pinch-point path sent unchanged as link offsets misses, by more than the link moves near the
/// base. When the reading at the tap reported the pinch point (`offset` given), the move follows the measured offset
/// (pinch point less gripper link): each fresh reading moves the link command `followShare` of the way to the path
/// less the offset's change since the tap, and the gripper link asked for stays inside the box less the tap's offset.
/// Four rules keep that feedback safe. The command moves no faster than the readings can keep up (`paceGain`): where
/// the jaws swing more than the link moves, a following error grows with speed. A fresh reading farther than
/// `pathWatchTolerances` arrive tolerances from the leg ahead (from where the command was `settleS` before it was
/// measured) ends the move stopped short: the pinch point is not going where it is sent (a point out of reach, a
/// posture where the jaws move against the link, a blocked arm). A fresh reading that no longer reports the pinch
/// point ends the move stopped short too: the arm stops where it is, so nothing jumps, and nothing is steered on an
/// estimate. And while the newest reading is stale the command waits where it is, since nothing then says where the
/// jaws went. Without a reported pinch point at the tap, nothing here changes the move.
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
    /// Each fresh reading moves the link command this share of the way to the offset it measured. The whole way
    /// overshoots where the jaws swing more than the link moves, since a reading shows a command's effect only one or
    /// two readings later.
    static let followShare = 0.5
    /// The command moves at the profile's speed times min(1, paceGain / swing), swing being the measured offset's
    /// change per unit of gripper-link travel over the newest `settleMoveM` or more of it; never below `slowestShare`
    /// of the speed, and at `startShare` until the first swing is measured.
    static let paceGain = 0.25
    static let slowestShare = 0.15
    static let startShare = 0.5
    /// A fresh reading this many arrive tolerances from the leg ahead ends a following move stopped short.
    static let pathWatchTolerances = 2.5

    /// The measured pinch point at the tap, robot base frame, metres.
    let start: SIMD3<Double>
    /// The tapped point at the travel height. Corrections never move it, and arrival is judged against it.
    let target: SIMD3<Double>
    let limits: GoToLimits
    /// The work box the tapped point was judged against, robot base frame, pinch point, metres, corners sorted. No
    /// correction ends outside it.
    let boxLow: SIMD3<Double>
    let boxHigh: SIMD3<Double>
    /// The tap, on the input rules' clock.
    let startedAt: TimeInterval
    private(set) var stage: Stage
    private(set) var correctionsLeft: Int
    /// The input rules end the move here.
    private(set) var deadline: TimeInterval
    /// How far vertical corrections raised the commanded height so that the measured pinch point holds the travel
    /// height. Never negative: the level leg's command is the travel height plus it. A correction at the end may come
    /// down from it, never below the travel height. The target never moves.
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
    /// The measured gripper-to-pinch offset of the reading at the tap, when the server reported the pinch point; nil:
    /// the move follows nothing.
    private let tapOffset: SIMD3<Double>?
    /// What the link command takes off the planned path: at each fresh reading it moves `followShare` of the way to
    /// that reading's change of offset since the tap.
    private var drift = SIMD3<Double>.zero
    /// When the newest reading taken into the following was measured.
    private var lastReadingAt = -TimeInterval.infinity
    /// The gripper link and the offset where the swing was last measured.
    private var paceLink: SIMD3<Double>?
    private var paceOffset = SIMD3<Double>.zero
    /// The share of the profile's speed the command moves at now.
    private var speedShare = 1.0
    /// A pace measured after the current leg's command ended: the next leg starts at it.
    private var nextShare: Double?
    /// Since when a following move's command has waited for a fresh reading.
    private var frozenSince: TimeInterval?
    /// A fresh reading was off the leg ahead, or did not report the pinch point: the move ends stopped short.
    private var endShort = false

    private struct Settle: Equatable, Sendable {
        var anchor: SIMD3<Double>
        var measuredAt: TimeInterval
    }

    /// - start: the measured pinch point at the tap. - target: the tapped point at the travel height. - now: the tap.
    /// - boxLow, boxHigh: opposite corners of the work box the target was judged against, either order. Left out,
    ///   nothing but the travel height bounds a correction.
    /// - offset: the measured gripper-to-pinch offset of the reading `start` came from, when the server reported the
    ///   pinch point. Left out, the move follows nothing.
    init(
        start: SIMD3<Double>, target: SIMD3<Double>, limits: GoToLimits, at now: TimeInterval,
        boxLow: SIMD3<Double> = SIMD3(repeating: -.infinity), boxHigh: SIMD3<Double> = SIMD3(repeating: .infinity),
        offset: SIMD3<Double>? = nil
    ) {
        self.start = start
        self.target = target
        self.limits = limits
        self.boxLow = simd_min(boxLow, boxHigh)
        self.boxHigh = simd_max(boxLow, boxHigh)
        startedAt = now
        stage = .vertical
        correctionsLeft = limits.corrections
        legFrom = start
        legTo = SIMD3(start.x, start.y, target.z)
        legStartedAt = now
        let path = abs(target.z - start.z) + simd_length(SIMD2(target.x - start.x, target.y - start.y))
        deadline = now + path / limits.speedMps * limits.timeFactor + limits.allowanceS
        tapOffset = offset
        if offset != nil {
            speedShare = Self.startShare
            deadline += path / limits.speedMps * (1 / Self.startShare - 1) * limits.timeFactor
        }
    }

    /// When the current leg's command reaches its end. At and after this moment `commanded` is the leg's end exactly.
    private var legEndsAt: TimeInterval {
        legStartedAt + simd_length(legTo - legFrom) / (limits.speedMps * speedShare)
    }

    private var isVerticalStage: Bool { stage == .vertical || stage == .correcting(.vertical) }

    /// The commanded pinch point at `time`: along the current leg at its share of `speedMps`, then its end, exactly;
    /// where it waits, while a following move waits for a fresh reading.
    func commanded(at time: TimeInterval) -> SIMD3<Double> {
        if frozenSince != nil { return legFrom }
        let length = simd_length(legTo - legFrom)
        // Over by time; no computed point is compared with the leg's end.
        guard length > 0, time < legEndsAt else { return legTo }
        let share = max(0, time - legStartedAt) * (limits.speedMps * speedShare) / length
        return legFrom + (legTo - legFrom) * share
    }

    /// What the link sends: the whole way asked for since the start, in the frame `TeleopLink.poseUpdate` takes. A
    /// translation moves the gripper link and the pinch point alike only while the gripper keeps its direction; a
    /// following move takes off what the measured offset has changed (`drift`), and keeps the gripper link it asks for
    /// inside the box less the tap's offset, which is the server's box for the gripper link.
    func linkOffset(at time: TimeInterval) -> SIMD3<Double> {
        guard let tapOffset else { return OperatorFrame.link(fromBase: commanded(at: time) - start) }
        let link = simd_clamp(commanded(at: time) - tapOffset - drift, boxLow - tapOffset, boxHigh - tapOffset)
        return OperatorFrame.link(fromBase: link - (start - tapOffset))
    }

    /// Judges the newest measured arm at `now`; nil while the move goes on. Changes legs and aims as it goes.
    mutating func observe(_ fix: ArmFix?, at now: TimeInterval) -> Verdict? {
        guard let fix, fix.ageS <= limits.armDataTimeoutS else { return .noArmData }
        if fix.holdPaused { pausedUntil = now }
        // A stale fix says nothing either way: no arrival, no corner, no settle.
        guard fix.ageS <= Self.freshS else {
            settle = nil
            // A following move does not go on blind: the command waits where it is for a fresh reading.
            if tapOffset != nil { freeze(at: now) }
            return nil
        }
        if tapOffset != nil { thaw(at: now) }
        let measuredAt = now - fix.ageS
        var pinch = fix.pinch
        if tapOffset != nil {
            pinch = follow(fix, measuredAt: measuredAt, now: now)
            if endShort { return .stoppedShort }
        }
        if simd_distance(pinch, start) >= Self.settleMoveM { seenMoving = true }
        if simd_distance(pinch, target) <= limits.arriveToleranceM { return .arrived }
        let atLegEnd = now >= legEndsAt
        // Only a measured point lower than the travel height less the tolerance holds the corner: sweeping low is what
        // this guards against, and an arm above the travel height comes down towards it along the level leg.
        if isVerticalStage, atLegEnd, target.z - pinch.z <= limits.arriveToleranceM {
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
        if let settle, simd_distance(pinch, settle.anchor) <= Self.settleMoveM {
            guard measuredAt - settle.measuredAt >= limits.settleS else { return nil }
        } else {
            settle = Settle(anchor: pinch, measuredAt: measuredAt)
            return nil
        }
        // Settled short of where this leg goes.
        if isVerticalStage {
            // Settled below the travel height less the tolerance, since anything higher turned the corner above, so
            // the missing height is positive and a correction here only ever raises the command. Only how far the
            // command goes to hold the travel height changes; the target stays where it was tapped.
            let missing = target.z - pinch.z
            guard correctionsLeft > 0, missing <= limits.correctionReachM else { return .stoppedShort }
            correctionsLeft -= 1
            // Never above the box's top: the raise is what the box leaves room for, and the level leg keeps that
            // much. The time limit grows by the whole height missing, as it does at the end.
            let raise = max(0, min(missing, boxHigh.z - legTo.z))
            heightAim += raise
            deadline += missing / limits.speedMps * limits.timeFactor + limits.settleS
            begin(.correcting(.vertical), to: legTo + SIMD3(0, 0, raise), at: now)
        } else {
            let remainder = target - pinch
            guard correctionsLeft > 0, simd_length(remainder) <= limits.correctionReachM else { return .stoppedShort }
            correctionsLeft -= 1
            deadline += simd_length(remainder) / limits.speedMps * limits.timeFactor + limits.settleS
            // The end moves by all that is missing: across, up if the jaws hang low, and down by a raise that was
            // false (the server held the arm below the travel height without saying so, and the move took it for
            // sagging jaws). Never below the travel height itself: an arm resting on something above it would
            // otherwise have the command pressed down into it at the target. Nor outside the box, where the target
            // lies: near a face, an arm held short (by a server whose box is smaller, or by something in the way)
            // would otherwise have the command sent past the face, farther with each correction. Either arm settles
            // short again and stops short. The time limit grows by the whole remainder, even when the floor or the
            // box shortens the leg.
            var end = simd_clamp(legTo + remainder, boxLow, boxHigh)
            end.z = max(end.z, target.z)
            begin(.correcting(.level), to: end, at: now)
        }
        return nil
    }

    /// Takes a fresh reading into the following: moves the drift, sets the pace and watches the leg. Returns the pinch
    /// point to judge by.
    private mutating func follow(_ fix: ArmFix, measuredAt: TimeInterval, now: TimeInterval) -> SIMD3<Double> {
        let pinch = fix.pinch
        guard let tapOffset, let gripper = fix.gripper, measuredAt > lastReadingAt else { return pinch }
        lastReadingAt = measuredAt
        guard fix.pinchReported else {
            endShort = true
            return pinch
        }
        let offset = pinch - gripper
        drift += (offset - tapOffset - drift) * Self.followShare
        if let from = paceLink {
            let travel = simd_distance(gripper, from)
            if travel >= Self.settleMoveM {
                let swing = simd_distance(offset, paceOffset) / travel
                let share = min(1, max(Self.slowestShare, Self.paceGain / max(swing, 1e-9)))
                paceLink = gripper
                paceOffset = offset
                let pace = nextShare ?? speedShare
                if abs(share - pace) > 0.05 * pace { changePace(to: share, at: now) }
            }
        } else {
            paceLink = gripper
            paceOffset = offset
        }
        // The leg ahead, along the current leg to its end: from where the command was a settle time before the reading
        // was measured, or from where it was when the leg began, when its pace last changed or when the command last
        // waited for a fresh reading, if that is later.
        let from = commanded(at: measuredAt - limits.settleS)
        let leg = legTo - from
        let lengthSquared = simd_length_squared(leg)
        let along = lengthSquared > 0 ? min(1, max(0, simd_dot(pinch - from, leg) / lengthSquared)) : 0
        if simd_distance(pinch, from + leg * along) > Self.pathWatchTolerances * limits.arriveToleranceM {
            endShort = true
        }
        return pinch
    }

    /// Goes on along the same leg at another share of the speed, from where the command is now, so it never jumps; a
    /// slower pace adds the time the rest of the leg now takes to the time limit.
    private mutating func changePace(to share: Double, at now: TimeInterval) {
        // A leg whose command has reached its end keeps it there: the new pace is for the legs after it. Changing the
        // share of an ended leg would move its end time past now and take the command back along the leg.
        guard now < legEndsAt else {
            nextShare = share
            return
        }
        let here = commanded(at: now)
        if share < speedShare {
            deadline += simd_length(legTo - here) / limits.speedMps * (1 / share - 1 / speedShare) * limits.timeFactor
        }
        legFrom = here
        legStartedAt = now
        speedShare = share
    }

    /// Holds the command where it is now; the leg goes on from there at `thaw`.
    private mutating func freeze(at now: TimeInterval) {
        guard frozenSince == nil else { return }
        let here = commanded(at: now)
        if now < legEndsAt {
            legFrom = here
        } else {
            legFrom = legTo
        }
        frozenSince = now
    }

    /// Goes on along the leg from where it waited; the time limit grows by the wait.
    private mutating func thaw(at now: TimeInterval) {
        guard let since = frozenSince else { return }
        frozenSince = nil
        legStartedAt = now
        deadline += now - since
    }

    /// Starts a leg from where the command is now, so the commanded point never jumps.
    private mutating func begin(_ next: Stage, to end: SIMD3<Double>, at now: TimeInterval) {
        legFrom = commanded(at: now)
        if let nextShare {
            speedShare = nextShare
            self.nextShare = nil
        }
        legTo = end
        legStartedAt = now
        stage = next
        settle = nil
    }
}
