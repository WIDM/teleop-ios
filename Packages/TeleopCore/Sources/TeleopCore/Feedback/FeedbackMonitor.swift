import simd

/// Robot numbers the monitor judges the gripper by, in the unit of the jaw reading (`GripperProfile.unit`). The app
/// fills them from its robot profile.
public struct GripperLimits: Equatable, Sendable {
    /// A measured jaw reading at or above this while opening is fully open.
    public var fullyOpenAt: Double
    /// A measured jaw reading at or below this when a close has ended with no contact: closed on nothing.
    public var emptyAt: Double

    public init(fullyOpenAt: Double, emptyAt: Double) {
        self.fullyOpenAt = fullyOpenAt
        self.emptyAt = emptyAt
    }
}

/// Turns what the link and the listening connection report into the events of `FeedbackEvent`, for the one
/// hold the operator has engaged. Pure: time is passed in, in milliseconds.
///
/// - GO when a start went out and no refusal came within the acceptance time (I-4).
/// - NO for a start the server refused within that time; LETGO for a refusal after it, or for a hold the app ends.
/// - END at a workspace or wrist clamp the server reports, at fully open, on a close that ended empty, and when the
///   arm is blocked: during a translation hold the commanded point is at least 10 mm ahead and the measured arm makes
///   little progress in 1.0 s.
/// - GRIP on contact while closing, or in the states that follow letting go of a close; from then on the jaws count
///   as gripping until an open, a scene reset or a new server run.
/// - Nothing for a hold the server ends with a success, and nothing judged while the success shows.
/// - With `reportsLowest` (the guide's aids), END for an arm that cannot go lower, still in height while the operator
///   asks for lower, in place of blocked when both cues qualify.
public struct FeedbackMonitor {
    public enum TranslationPoint: Equatable, Sendable { case linkOrigin, tool }

    public static let acceptMinMs = 100
    public static let acceptMaxMs = 300
    public static let acceptMarginMs = 50
    /// Round trips the acceptance time is the median of.
    public static let roundTripWindow = 10
    public let limits: GripperLimits
    /// The numbers of the blocked rule and of the lowest rule, from the robot's profile (`robot` response section).
    public let blockedRule: BlockedRule
    public let lowestRule: LowestRule
    /// How the base frame relates to the operator's view: "height", "lower" and "lowest" below are along its up.
    public let frames: Frames
    /// Gripper-link bounds in the active robot profile. Never applied to tool-point targets.
    public var blockedWorkspace: (low: SIMD3<Double>, high: SIMD3<Double>)?
    /// With the guide's aids on: an arm that stands against the operator's ask for lower is `.limit(.lowest)`, told
    /// once per approach and not silenced by an earlier clamp in the same hold (pushing down past the box's floor sets
    /// the clamp label, just when the operator needs to hear it); `.limit(.blocked)` stays silent while the operator
    /// asks for lower when the directional blocked rule is off. False forgets both lowest heights.
    public var reportsLowest = false {
        didSet {
            if !reportsLowest {
                lowestSeen = nil
                lowestPinchSeen = nil
            }
        }
    }
    /// The lowest gripper-link height, along up (`Frames.height(of:)`), at which the arm stood against an ask for lower
    /// since the control connection was welcomed; a lower stall replaces it. Nil before one, and with `reportsLowest` off.
    public private(set) var lowestSeen: Double?
    /// The same for the pinch point's height, from stalls whose newest state carries the pinch point; nil before one.
    /// Forgotten whenever `lowestSeen` is.
    public private(set) var lowestPinchSeen: Double?

    /// One state of a translation hold that carried the gripper link's position.
    private struct Sample {
        let atMs: Int
        /// The selected translation control point, robot base frame.
        let position: SIMD3<Double>
        let origin: SIMD3<Double>
        /// The pinch point, robot base frame, when the state carries it.
        let pinch: SIMD3<Double>?
        /// The heights, along up, of `position`, `origin` and `pinch`.
        let height: Double
        let originHeight: Double
        let pinchHeight: Double?
        /// How far the commanded point held when the state arrived lay under its selected control point, along up; nil
        /// before the first command. It is never judged again against a later command.
        let below: Double?
        let request: SIMD3<Double>?
        /// Nil for an ordinary state, false for a clamp before this segment has tracked.
        let clamp: Bool?
    }

    /// Where a downward approach was told: the newest state's height then (the pinch point's when it carried it,
    /// else the gripper link's) and the gripper link's height.
    private struct ToldHeight {
        let height: Double
        let ofPinch: Bool
        let gripperHeight: Double
        let blockedLead: SIMD3<Double>?

        init(_ sample: Sample, blockedLead: SIMD3<Double>? = nil) {
            height = sample.pinchHeight ?? sample.height
            ofPinch = sample.pinch != nil
            gripperHeight = sample.originHeight
            self.blockedLead = blockedLead
        }
    }

    /// The operator's hold from its first start until it ends. A hold the app restarts on its own stays the same hold.
    private struct Engaged {
        let hold: Int
        var kind: ControlKind
        var sentAtMs: Int
        let beganAtMs: Int
        var accepted = false
        /// The hold's own label (`pose_tracking`, `orienting`) has been seen since its start, so a clamp label
        /// from now on is this hold's, not one left over from the hold before.
        var ownLabelSeen = false
        var clamped = false
        var contact = false
        var fullyOpen = false
        var blocked = false
        var workspaceExplainsStall = false
        /// Where this downward approach was told; nil while the lowest cue is armed.
        var lowestTold: ToldHeight?
        /// Where the app is sending the arm, robot base frame.
        var target: SIMD3<Double>?
        var point: TranslationPoint = .linkOrigin
        var samples: [Sample] = []
        /// The link has ended the server hold to learn where the arm got to and has not re-sent the start yet.
        var resyncing = false
    }

    private var engaged: Engaged?
    /// A close the operator let go of before any contact showed. The server handles the stop a step later, and
    /// with the listening connection down the first state comes only after the stop, so contact in the states
    /// that follow still counts (§5.7). Kept apart from the engaged hold: a translation or wrist hold started before
    /// that state leaves it to be decided, and only a new jog of the jaws takes over from it.
    private var releasedClose = false
    private var nextHold = 1
    private var roundTrips: [Int] = []
    private var episode: Int?
    private var session: String?
    /// A close ended in contact and nothing has opened since, no scene reset, no new server run.
    public private(set) var gripping = false

    public init(limits: GripperLimits, frames: Frames, blocked: BlockedRule, lowest: LowestRule) {
        self.limits = limits
        self.frames = frames
        blockedRule = blocked
        lowestRule = lowest
    }

    /// The operator's hold engaged now, if any.
    public var engagedHold: Int? { engaged?.hold }

    /// How long after a start goes out it counts as accepted: the median round trip plus a margin, within bounds.
    public var acceptanceMs: Int {
        guard !roundTrips.isEmpty else { return Self.acceptMaxMs }
        let median = roundTrips.sorted()[roundTrips.count / 2]
        return min(max(median + Self.acceptMarginMs, Self.acceptMinMs), Self.acceptMaxMs)
    }

    public mutating func roundTrip(ms: Int) {
        roundTrips.append(ms)
        if roundTrips.count > Self.roundTripWindow { roundTrips.removeFirst(roundTrips.count - Self.roundTripWindow) }
    }

    /// A start went on the wire. `restart`: the app restarted a hold the operator still holds, as a translation
    /// resync does; it has already had its GO.
    public mutating func startSent(_ kind: ControlKind, restart: Bool, at now: Int) {
        if case .gripper = kind { releasedClose = false }
        if kind == .gripper(.open) { gripping = false }
        if restart, var current = engaged {
            current.kind = kind
            current.sentAtMs = now
            current.ownLabelSeen = false
            current.resyncing = false
            current.workspaceExplainsStall = false
            if blockedWorkspace != nil || current.point == .tool { current.target = nil }
            engaged = current
            return
        }
        engaged = Engaged(hold: nextHold, kind: kind, sentAtMs: now, beganAtMs: now)
        nextHold += 1
    }

    /// The server refused or ended the engaged hold, with this reason.
    public mutating func startRefused(reason: String, at now: Int) -> [FeedbackEvent] {
        guard let current = engaged else { return [] }
        engaged = nil
        // A success is told by the recorder narration, and an emergency stop by its own event; neither is a
        // refusal or a let-go.
        if reason == TeleopLink.successReason || Self.emergencyStopReasons.contains(reason) { return [] }
        // A reason the operator can act on is told by what to do; any other keeps the general words.
        let refusalClass = ServerRefusalClass(reason: reason)
        if !current.accepted {
            switch reason {
            case "busy": return [.refused(.busy)]
            case "sim_not_ready": return [.refused(.notReady)]
            case "estop_active": return [.refused(.emergencyStop)]
            default:
                return [
                    refusalClass == .other ? .refused(.serverRefused) : .serverRefusal(refusalClass, accepted: false)
                ]
            }
        }
        if reason.hasSuffix("_watchdog_timeout") { return [.letGo(.watchdog)] }
        return [refusalClass == .other ? .letGo(.lateRejection) : .serverRefusal(refusalClass, accepted: true)]
    }

    /// The operator let go of `kind` and the app sent its stop; nil: whatever is engaged. A stop for another kind
    /// than the one engaged (the gripper's, after a wrist turn took over) changes nothing.
    public mutating func released(_ kind: ControlKind? = nil) {
        guard let current = engaged, let kind else {
            engaged = nil
            releasedClose = false
            return
        }
        switch (current.kind, kind) {
        case (.pose, .pose), (.wrist, .wrist): engaged = nil
        case (.gripper(let target), .gripper):
            engaged = nil
            releasedClose = target == .closed && !current.contact
        default: break
        }
    }

    /// The app ended the hold while the operator still holds it.
    public mutating func endedByApp(_ reason: LetGoReason) -> [FeedbackEvent] {
        guard engaged != nil else { return [] }
        engaged = nil
        return [.letGo(reason)]
    }

    /// The link ended the translation hold's server hold to learn where the arm got to (a resync), and has not
    /// re-sent its start yet; `startSent(restart: true)` ends the pause. Meanwhile the arm stands still because the
    /// link stopped it, which says nothing about where it can go: with `reportsLowest` on, a state that arrives adds
    /// no sample and nothing is judged, so no stall can span the pause. Samples from before it are kept. This is the
    /// resync's pause alone, not every time the link holds the arm short: a command held at the lead cap, with the
    /// hand far ahead, is exactly a push into the table, and an arm that stands against it must still be told. With
    /// `reportsLowest` off this changes nothing.
    public mutating func resyncBegan() {
        guard engaged?.kind == .pose else { return }
        engaged?.resyncing = true
    }

    /// Where the app is sending the arm now in a translation hold, robot base frame.
    public mutating func commanded(_ target: SIMD3<Double>, point: TranslationPoint = .linkOrigin) {
        guard var current = engaged, current.kind == .pose else { return }
        if current.point != point {
            current.samples.removeAll()
            current.lowestTold = nil
        }
        current.target = target
        current.point = point
        engaged = current
    }

    /// The acceptance time passing.
    public mutating func tick(at now: Int) -> [FeedbackEvent] {
        guard var current = engaged, !current.accepted, now - current.sentAtMs >= acceptanceMs else { return [] }
        current.accepted = true
        engaged = current
        return [.holdLive(hold: current.hold)]
    }

    /// A `state` from either connection, as it arrived.
    public mutating func observe(_ state: ServerState, at now: Int) -> [FeedbackEvent] {
        if let number = state.episode {
            if let before = episode, before != number { gripping = false }
            episode = number
        }
        // The outcome of the close let go of, told before whatever the hold engaged since makes of this state.
        var closeOutcome: [FeedbackEvent] = []
        if releasedClose {
            switch state.activity {
            case .gripperContact? where !state.estop:
                releasedClose = false
                gripping = true
                closeOutcome = [.contact]
            // The server has not handled the stop yet: the jaws are still closing.
            case .gripperJogging? where !state.estop: break
            default:
                // The close has ended without contact. Only now are shut jaws empty: while they close, contact can
                // still come after the angle has passed the limit, and a grip on a small object rests under it.
                releasedClose = false
                if !state.estop, let angle = state.gripperDeg, angle <= limits.emptyAt {
                    closeOutcome = [.limit(.empty)]
                }
            }
        }
        // While the success shows nothing moves on purpose, and the hold has ended or is about to.
        guard var current = engaged, now >= current.sentAtMs, !state.estop, !state.simBusy else { return closeOutcome }
        var events = closeOutcome
        switch current.kind {
        case .pose:
            if state.activity == .poseTracking { current.ownLabelSeen = true }
            if state.activity == .poseClamped, current.ownLabelSeen, !current.clamped {
                current.clamped = true
                events.append(.limit(.workspace))
            }
            // The lowest rule neither samples nor judges an arm the link itself has stopped for a resync.
            let pausedByTheLink =
                (reportsLowest || blockedWorkspace != nil || current.point == .tool) && current.resyncing
            if !pausedByTheLink {
                let measured = current.point == .tool ? state.toolPoint : state.endEffector
                if let position = measured, position.indices.allSatisfy({ position[$0].isFinite }),
                    let origin = state.endEffector, origin.indices.allSatisfy({ origin[$0].isFinite })
                {
                    let request = current.target
                    let below = request.map { frames.height(of: position) - frames.height(of: $0) }
                    let clamp = state.activity == .poseClamped ? current.ownLabelSeen : nil
                    if current.workspaceExplainsStall, state.activity == .poseTracking, let request,
                        Self.length(position - request) < blockedRule.movedM
                    {
                        current.workspaceExplainsStall = false
                    }
                    current.samples.append(
                        Sample(
                            atMs: now, position: position, origin: origin, pinch: state.toolPoint,
                            height: frames.height(of: position), originHeight: frames.height(of: origin),
                            pinchHeight: state.toolPoint.map { frames.height(of: $0) }, below: below,
                            request: request, clamp: clamp))
                    current.samples.removeAll { now - $0.atMs > blockedRule.windowMs + blockedRule.freshMs * 2 }
                }
                if reportsLowest { events += judgeHeight(&current, at: now) }
                // With the lowest rule on, a pinch point asked at least 10 mm lower is that rule's to judge, as on the
                // gripper link's path (`isBlockedWithoutAskingLower`). It waits until the arm has stopped coming down;
                // an arm a slow simulator brings down under 2 mm a second is otherwise taken here for one that does
                // not follow. Only asks that rule can judge are left to it (`lowestRuleCanJudge`): any other ask would
                // get neither cue.
                let lowestRuleJudges =
                    reportsLowest && current.point == .tool && asksLowerThisSecond(current, frames)
                    && lowestRuleCanJudge(current)
                if !current.blocked, blockedWorkspace != nil || current.point == .tool, !lowestRuleJudges,
                    isNotFollowing(&current, workspace: current.point == .tool ? nil : blockedWorkspace, at: now),
                    let newest = current.samples.last
                {
                    current.blocked = true
                    if let below = newest.below, below >= lowestRule.sustainM, let request = newest.request {
                        current.lowestTold = ToldHeight(newest, blockedLead: request - newest.position)
                    }
                    events.append(.limit(.blocked))
                } else if current.point == .linkOrigin, blockedWorkspace == nil, !reportsLowest, !current.blocked,
                    !current.clamped,
                    isBlocked(current, at: now)
                {
                    current.blocked = true
                    events.append(.limit(.blocked))
                }
            }
        case .wrist:
            if state.activity == .orienting { current.ownLabelSeen = true }
            if state.activity == .orientClamped, current.ownLabelSeen, !current.clamped {
                current.clamped = true
                events.append(.limit(.wrist))
            }
        case .gripper(.closed):
            // Empty is decided after the close ends (above), never from the angle while it runs.
            if state.activity == .gripperContact, !current.contact {
                current.contact = true
                gripping = true
                events.append(.contact)
            }
        case .gripper(.open):
            if !current.fullyOpen, let angle = state.gripperDeg, angle >= limits.fullyOpenAt {
                current.fullyOpen = true
                events.append(.limit(.fullyOpen))
            }
        }
        engaged = current
        return events
    }

    /// A new control connection's `welcome`. A different server run has a different scene.
    public mutating func welcomed(session: String?) {
        if session != self.session { gripping = false }
        self.session = session
        releasedClose = false
        lowestSeen = nil
        lowestPinchSeen = nil
    }

    /// The server reset the scene: the jaws hold nothing.
    public mutating func sceneReset() {
        gripping = false
        releasedClose = false
    }

    /// The control connection is gone; nothing is engaged any more.
    public mutating func linkClosed() {
        engaged = nil
        releasedClose = false
    }

    static let emergencyStopReasons: Set<String> = [
        "estop", "disconnect_estop", "pose_tracking_safety_stop", "tracking_safety_stop", "pose_nonfinite_ik",
        "pose_wrist_invalid_input", "pose_wrist_nonfinite_state",
    ]

    /// The server ended a hold for a reason another cue already tells: a success, told by the recorder narration; an
    /// emergency-stop reason, told by the alarm; or `estop_active`, also told by the alarm. `startRefused` returns
    /// nothing for the first two and, before acceptance, `.refused(.emergencyStop)` for the third, which no drive
    /// ending names; after acceptance a stopped robot's answer comes back as a let-go, which the link drops for a move
    /// nobody holds, since the alarm tells it. So a move nobody holds that the server ended for one of these was told,
    /// though nothing was emitted for it.
    public static func isToldElsewhere(_ reason: String) -> Bool {
        reason == TeleopLink.successReason || emergencyStopReasons.contains(reason) || reason == "estop_active"
    }

    /// The commanded point is far ahead and the measured arm has stood still for the whole window.
    private func isBlocked(_ hold: Engaged, at now: Int) -> Bool {
        guard let target = hold.target, let newest = hold.samples.last, now - newest.atMs < blockedRule.freshMs,
            Self.length(target - newest.position) >= blockedRule.shortM,
            let oldest = hold.samples.last(where: { newest.atMs - $0.atMs >= blockedRule.windowMs })
        else { return false }
        let window = hold.samples.filter { $0.atMs >= oldest.atMs }
        return window.allSatisfy { Self.length($0.position - oldest.position) < blockedRule.movedM }
    }

    /// An aided hold is blocked when a sustained request has a consistent lead but makes too little progress.
    private func isNotFollowing(
        _ hold: inout Engaged, workspace: (low: SIMD3<Double>, high: SIMD3<Double>)?, at now: Int
    ) -> Bool {
        let since = hold.point == .tool ? hold.beganAtMs : hold.sentAtMs
        let samples = hold.samples.filter { $0.atMs >= since && $0.request != nil }
        guard let newest = samples.last, now - newest.atMs < blockedRule.freshMs,
            let window = Self.window(of: samples, ms: blockedRule.windowMs), arrivesRegularly(window),
            let oldest = window.first
        else { return false }

        let requests = window.compactMap(\.request)
        let targets = requests.map { request in
            guard let workspace else { return request }
            return simd_min(simd_max(request, workspace.low), workspace.high)
        }
        let leads = zip(targets, window).map { $0 - $1.position }
        guard let firstLead = leads.first, let firstTarget = targets.first, let lastTarget = targets.last else {
            return false
        }
        let leadLength = Self.length(firstLead)
        guard leadLength >= blockedRule.shortM,
            leads.allSatisfy({ Self.length($0) >= blockedRule.shortM && pointsSameWay(firstLead, $0) })
        else { return false }

        let moved = newest.position - oldest.position
        guard
            simd_dot(moved, firstLead) / leadLength
                < min(blockedRule.movedM, leadLength * blockedRule.leadProgressShare),
            Self.length(moved) < blockedRule.exclusionM
        else { return false }
        let targetTravel = lastTarget - firstTarget
        let commandDistance = Self.length(targetTravel)
        if commandDistance >= blockedRule.movedM,
            simd_dot(moved, targetTravel) / commandDistance
                >= max(blockedRule.movedM, commandDistance * blockedRule.followingShare)
        {
            return false
        }

        let clamps = zip(window, targets).map { sample, target in
            guard sample.clamp != nil, let request = sample.request else { return false }
            return hold.clamped
                || target.indices.contains { axis in
                    abs(request[axis] - target[axis]) >= blockedRule.movedM
                        && abs(sample.position[axis] - target[axis]) <= blockedRule.movedM
                }
        }
        if window.contains(where: { $0.clamp == true }) || zip(clamps, clamps.dropFirst()).contains(where: { $0 && $1 })
        {
            hold.workspaceExplainsStall = true
        }
        return !hold.workspaceExplainsStall
    }

    // The lowest rule, used only with `reportsLowest` on.
    //
    // An arm on a table slides along it, so it is never still in all three directions for a second: the rule judges
    // its height alone, and asks for no direction, since a push that is partly sideways into the table stops the arm
    // as surely. The height is the pinch point's when the server reports it, because the gripper link's height on the
    // table changes with the arm's posture while the pinch point's does not. Each state is judged by the command held
    // when it arrived, and a window is judged only when its states arrived regularly, so states that come late, or
    // held back and all at once, cannot make a stall out of an arm that was moving.

    /// The lowest cue, once per approach, and "Blocked." when the operator is not asking for lower.
    private mutating func judgeHeight(_ hold: inout Engaged, at now: Int) -> [FeedbackEvent] {
        if let told = hold.lowestTold, let newest = hold.samples.last, hasLeftToldHeight(newest, told) {
            hold.lowestTold = nil
        }
        if isLowestStall(hold, at: now), let newest = hold.samples.last {
            // Both heights are kept from every stall, told or not.
            lowestSeen = min(lowestSeen ?? newest.originHeight, newest.originHeight)
            if let pinch = newest.pinchHeight { lowestPinchSeen = min(lowestPinchSeen ?? pinch, pinch) }
            guard hold.lowestTold == nil else { return [] }
            hold.lowestTold = ToldHeight(newest)
            // One stall, one cue: a told lowest is this hold's blocked cue as well.
            hold.blocked = true
            return [.limit(.lowest)]
        }
        guard hold.point == .linkOrigin, blockedWorkspace == nil, !hold.blocked, !hold.clamped,
            isBlockedWithoutAskingLower(hold, at: now, frames)
        else { return [] }
        hold.blocked = true
        return [.limit(.blocked)]
    }

    /// The fresh measured arm stands against the operator's ask for lower. The full stall: the newest state sent at
    /// least 10 mm lower, every state of the last second at least 5 mm lower, arriving regularly, and the height
    /// within 2 mm over that second. Or the quicker one, back within 2 mm of the lowest height found of the same kind:
    /// every state of the last 0.3 s at least 5 mm lower, arriving regularly, and the height within 1 mm. Neither while
    /// the height is still coming down over its window (`lowestRule.descentMps`).
    private func isLowestStall(_ hold: Engaged, at now: Int) -> Bool {
        guard hold.target != nil, let newest = hold.samples.last, now - newest.atMs < blockedRule.freshMs else {
            return false
        }
        if let below = newest.below, below >= blockedRule.shortM,
            let window = Self.window(of: hold.samples, ms: blockedRule.windowMs),
            Self.asks(window, atLeast: lowestRule.sustainM), arrivesRegularly(window),
            isStill(window, within: blockedRule.movedM), !isComingDown(window)
        {
            return true
        }
        let height = newest.pinchHeight ?? newest.height
        guard let lowest = newest.pinch == nil ? lowestSeen : lowestPinchSeen,
            abs(height - lowest) <= blockedRule.movedM,
            let window = Self.window(of: hold.samples, ms: lowestRule.quickMs),
            Self.asks(window, atLeast: lowestRule.quickShortM), arrivesRegularly(window)
        else { return false }
        return isStill(window, within: lowestRule.quickMovedM) && !isComingDown(window)
    }

    /// Version 1.0.1's blocked stall, silent while any state of its second was sent at least 10 mm lower (the operator
    /// is asking for lower, and the lowest rule answers that), and judged only over states that arrived regularly.
    private func isBlockedWithoutAskingLower(_ hold: Engaged, at now: Int, _ frames: Frames) -> Bool {
        guard isBlocked(hold, at: now), !asksLowerNow(hold, frames),
            let window = Self.window(of: hold.samples, ms: blockedRule.windowMs)
        else { return false }
        return arrivesRegularly(window) && !window.contains { $0.below.map { $0 >= blockedRule.shortM } ?? false }
    }

    /// The command held now is at least 10 mm under the newest state's gripper link. The operator is asking for lower
    /// although no state has arrived with that ask yet: a state without the gripper link's position adds no sample,
    /// and the next state with one is judged by the lowest rule.
    private func asksLowerNow(_ hold: Engaged, _ frames: Frames) -> Bool {
        guard let target = hold.target, let newest = hold.samples.last else { return false }
        return newest.height - frames.height(of: target) >= blockedRule.shortM
    }

    /// The command held now, or one held when a state of the last second arrived, is at least 10 mm under the measured
    /// point.
    private func asksLowerThisSecond(_ hold: Engaged, _ frames: Frames) -> Bool {
        guard let newest = hold.samples.last else { return false }
        return asksLowerNow(hold, frames)
            || hold.samples.contains {
                newest.atMs - $0.atMs <= blockedRule.windowMs && ($0.below.map { $0 >= blockedRule.shortM } ?? false)
            }
    }

    /// The asks of the newest states are ones the lowest rule can judge, whatever the arm does: every state of the last
    /// second asked at least 5 mm lower (the full stall), or, back within 2 mm of the lowest height found of the same
    /// kind, every state of the last 0.3 s asked as much as the quicker stall needs. True while there is no second of
    /// states yet: nothing is judged as blocked before then either.
    private func lowestRuleCanJudge(_ hold: Engaged) -> Bool {
        guard let window = Self.window(of: hold.samples, ms: blockedRule.windowMs) else { return true }
        if Self.asks(window, atLeast: lowestRule.sustainM) { return true }
        guard let newest = hold.samples.last,
            let lowest = newest.pinch == nil ? lowestSeen : lowestPinchSeen,
            abs((newest.pinchHeight ?? newest.height) - lowest) <= blockedRule.movedM,
            let quick = Self.window(of: hold.samples, ms: lowestRule.quickMs)
        else { return false }
        return Self.asks(quick, atLeast: lowestRule.quickShortM)
    }

    /// Rising 10 mm rearms the lowest cue. After a downward Blocked, a lower height or a new direction also rearms it.
    private func hasLeftToldHeight(_ newest: Sample, _ told: ToldHeight) -> Bool {
        let sameKind = (newest.pinch != nil) == told.ofPinch
        let measured = sameKind ? (newest.pinchHeight ?? newest.height) : newest.originHeight
        let previous = sameKind ? told.height : told.gripperHeight
        if measured >= previous + blockedRule.shortM { return true }
        guard let blockedLead = told.blockedLead else { return false }
        if measured <= previous - blockedRule.shortM { return true }
        guard let request = newest.request else { return false }
        let lead = request - newest.position
        return Self.length(lead) >= blockedRule.shortM && !pointsSameWay(blockedLead, lead)
    }

    /// A change of less than `sameWayDeg` is part of the same request.
    private func pointsSameWay(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool {
        simd_dot(a, b) > (simd_dot(a, a) * simd_dot(b, b)).squareRoot() * cos(blockedRule.sameWayDeg * .pi / 180)
    }

    /// From the last sample at least `ms` older than the newest to the newest, with every sample that arrived in that
    /// one's millisecond; nil while no sample is that old.
    private static func window(of samples: [Sample], ms: Int) -> [Sample]? {
        guard let newest = samples.last, let oldest = samples.last(where: { newest.atMs - $0.atMs >= ms }) else {
            return nil
        }
        return samples.filter { $0.atMs >= oldest.atMs }
    }

    /// Every sample was sent at least `meters` lower when it arrived; one that came before any command was not.
    private static func asks(_ window: [Sample], atLeast meters: Double) -> Bool {
        window.allSatisfy { $0.below.map { $0 >= meters } ?? false }
    }

    /// No two consecutive samples arrived more than `blockedRule.arrivalGapMs` apart.
    private func arrivesRegularly(_ window: [Sample]) -> Bool {
        zip(window, window.dropFirst()).allSatisfy { $1.atMs - $0.atMs <= blockedRule.arrivalGapMs }
    }

    /// Every sample's height is less than `meters` from the oldest's: the pinch point's when every sample carries it,
    /// the gripper link's for all of them otherwise.
    private func isStill(_ window: [Sample], within meters: Double) -> Bool {
        let heights = Self.heights(of: window)
        // Every height is measured against the window's first sample: of several that arrived in its first
        // millisecond, the one that arrived first.
        guard let oldest = heights.first else { return false }
        return heights.allSatisfy { abs($0 - oldest) < meters }
    }

    /// The window's heights fall at least `lowestRule.descentMps`, by the least-squares line through them: the
    /// arm is still coming down, however slowly the simulator runs. A line, not the first and newest heights alone,
    /// so one state that wavers decides nothing.
    private func isComingDown(_ window: [Sample]) -> Bool {
        let heights = Self.heights(of: window)
        guard let first = window.first, heights.count >= 2 else { return false }
        let seconds = window.map { Double($0.atMs - first.atMs) / 1000 }
        let meanTime = seconds.reduce(0, +) / Double(seconds.count)
        let meanHeight = heights.reduce(0, +) / Double(heights.count)
        let spread = seconds.reduce(0) { $0 + ($1 - meanTime) * ($1 - meanTime) }
        guard spread > 0 else { return false }
        let covariance = zip(seconds, heights).reduce(0) { $0 + ($1.0 - meanTime) * ($1.1 - meanHeight) }
        return covariance / spread <= -lowestRule.descentMps
    }

    /// The pinch point's heights when every sample carries it, the gripper link's for all of them otherwise.
    private static func heights(of window: [Sample]) -> [Double] {
        let pinchHeights = window.compactMap(\.pinchHeight)
        return pinchHeights.count == window.count ? pinchHeights : window.map(\.height)
    }

    private static func length(_ vector: SIMD3<Double>) -> Double { (vector * vector).sum().squareRoot() }
}
