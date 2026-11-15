/// Robot numbers the monitor judges the gripper by. The app fills them from its robot profile.
public struct GripperLimits: Equatable, Sendable {
    /// A measured jaw angle at or above this while opening is fully open.
    public var openDeg: Double
    /// A measured jaw angle at or below this while closing, with no contact, closed on nothing.
    public var emptyDeg: Double

    public init(openDeg: Double, emptyDeg: Double) {
        self.openDeg = openDeg
        self.emptyDeg = emptyDeg
    }
}

/// Turns what the link and the listening connection report into the events of `FeedbackEvent`, for the one
/// hold the operator has engaged. Pure: time is passed in, in milliseconds.
///
/// - GO when a start went out and no refusal came within the acceptance time (I-4).
/// - NO for a start the server refused within that time; LETGO for a refusal after it, or for a hold the app ends.
/// - END at a workspace or wrist clamp the server reports, at fully open, on an empty close, and when the arm is
///   blocked: during a translation hold the commanded point is at least 10 mm ahead and the measured arm moved
///   less than 2 mm in 1.0 s.
/// - GRIP on contact while closing, or in the states that follow letting go of a close; from then on the jaws count
///   as gripping until an open, a scene reset or a new server run.
/// - Nothing for a hold the server ends with a success, and nothing judged while the success shows.
/// - With `reportsLowest` (the guide's aids), END for an arm that cannot go lower, still in height while the operator
///   asks for lower, in place of blocked; blocked then stays silent while the operator asks for lower.
public struct FeedbackMonitor {
    public static let acceptMinMs = 100
    public static let acceptMaxMs = 300
    public static let acceptMarginMs = 50
    /// Round trips the acceptance time is the median of.
    public static let roundTripWindow = 10
    /// A measured position older than this says nothing about now.
    public static let freshStateMs = 400
    public static let blockedShortMeters = 0.010
    public static let blockedMovedMeters = 0.002
    public static let blockedWindowMs = 1000
    /// The lowest rule's quicker stall, back near the lowest height already found: every state of its window sent at
    /// least this much lower, and the height moved less than this in this long.
    public static let lowestQuickShortMeters = 0.005
    public static let lowestQuickMovedMeters = 0.001
    public static let lowestQuickMs = 300
    /// The lowest rule's full stall asks the newest state to be sent at least `blockedShortMeters` lower and every
    /// state of its second at least this much, so a hand that wavers around 10 mm still asks.
    public static let lowestSustainMeters = 0.005
    /// With the lowest rule on, no two states of a window it judges arrived further apart than this: states held back
    /// and delivered together say nothing about how the arm stood between them.
    public static let arrivalGapMs = 400

    public let limits: GripperLimits
    /// With the guide's aids on: an arm that stands against the operator's ask for lower is `.limit(.lowest)`, told
    /// once per approach and not silenced by an earlier clamp in the same hold (pushing down past the box's floor sets
    /// the clamp label, just when the operator needs to hear it); `.limit(.blocked)` stays silent while the operator
    /// asks for lower. False is version 1.0.1 in every rule, and forgets both lowest heights.
    public var reportsLowest = false {
        didSet {
            if !reportsLowest {
                lowestSeen = nil
                lowestPinchSeen = nil
            }
        }
    }
    /// The lowest gripper-link height, robot base frame, at which the arm stood against an ask for lower since the
    /// control connection was welcomed; a lower stall replaces it. Nil before one, and with `reportsLowest` off.
    public private(set) var lowestSeen: Double?
    /// The same for the pinch point's height, from stalls whose newest state carries the pinch point; nil before one.
    /// Forgotten whenever `lowestSeen` is.
    public private(set) var lowestPinchSeen: Double?

    /// One state of a translation hold that carried the gripper link's position.
    private struct Sample {
        let atMs: Int
        /// The gripper link, robot base frame.
        let position: SIMD3<Double>
        /// The pinch point, robot base frame, when the state carries it.
        let pinch: SIMD3<Double>?
        /// How far the commanded point held when the state arrived lay under its gripper link; nil before the first
        /// command. It is never judged again against a later command.
        let below: Double?
    }

    /// Where the lowest cue was told: the newest state's height then (the pinch point's when that state carried it,
    /// else the gripper link's) and the gripper link's height.
    private struct ToldHeight {
        let height: Double
        let ofPinch: Bool
        let gripperZ: Double
    }

    /// The operator's hold from its first start until it ends. A hold the app restarts on its own stays the same hold.
    private struct Engaged {
        let hold: Int
        var kind: ControlKind
        var sentAtMs: Int
        var accepted = false
        /// The hold's own label (`pose_tracking`, `orienting`) has been seen since its start, so a clamp label
        /// from now on is this hold's, not one left over from the hold before.
        var ownLabelSeen = false
        var clamped = false
        var contact = false
        var empty = false
        var fullyOpen = false
        var blocked = false
        /// Where the lowest cue was told in this approach; nil while it is armed.
        var lowestTold: ToldHeight?
        /// Where the app is sending the arm, robot base frame.
        var target: SIMD3<Double>?
        var samples: [Sample] = []
    }

    private var engaged: Engaged?
    /// A close the operator let go of before any contact showed. The server handles the stop a step later, and
    /// with the listening connection down the first state comes only after the stop, so contact in the states
    /// that follow still counts (§5.7).
    private var releasedClose = false
    private var nextHold = 1
    private var roundTrips: [Int] = []
    private var episode: Int?
    private var session: String?
    /// A close ended in contact and nothing has opened since, no scene reset, no new server run.
    public private(set) var gripping = false

    public init(limits: GripperLimits) {
        self.limits = limits
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
        releasedClose = false
        if kind == .gripper(.open) { gripping = false }
        if restart, var current = engaged {
            current.kind = kind
            current.sentAtMs = now
            current.ownLabelSeen = false
            engaged = current
            return
        }
        engaged = Engaged(hold: nextHold, kind: kind, sentAtMs: now)
        nextHold += 1
    }

    /// The server refused or ended the engaged hold, with this reason.
    public mutating func startRefused(reason: String, at now: Int) -> [FeedbackEvent] {
        guard let current = engaged else { return [] }
        engaged = nil
        // A success is told by the recorder narration, and an emergency stop by its own event; neither is a
        // refusal or a let-go.
        if reason == TeleopLink.successReason || Self.emergencyStopReasons.contains(reason) { return [] }
        if !current.accepted {
            switch reason {
            case "busy": return [.refused(.busy)]
            case "sim_not_ready": return [.refused(.notReady)]
            case "estop_active": return [.refused(.emergencyStop)]
            default: return [.refused(.serverRefused)]
            }
        }
        return [.letGo(reason.hasSuffix("_watchdog_timeout") ? .watchdog : .lateRejection)]
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

    /// Where the app is sending the arm now in a translation hold, robot base frame.
    public mutating func commanded(_ target: SIMD3<Double>) {
        guard engaged?.kind == .pose else { return }
        engaged?.target = target
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
        if releasedClose {
            switch state.activity {
            case .gripperContact? where !state.estop:
                releasedClose = false
                gripping = true
                return [.contact]
            // The server has not handled the stop yet: the jaws are still closing.
            case .gripperJogging? where !state.estop: break
            default: releasedClose = false
            }
        }
        // While the success shows nothing moves on purpose, and the hold has ended or is about to.
        guard var current = engaged, now >= current.sentAtMs, !state.estop, !state.simBusy else { return [] }
        var events: [FeedbackEvent] = []
        switch current.kind {
        case .pose:
            if state.activity == .poseTracking { current.ownLabelSeen = true }
            if state.activity == .poseClamped, current.ownLabelSeen, !current.clamped {
                current.clamped = true
                events.append(.limit(.workspace))
            }
            if let position = state.endEffector {
                let below = current.target.map { position.z - $0.z }
                current.samples.append(Sample(atMs: now, position: position, pinch: state.toolPoint, below: below))
                current.samples.removeAll { now - $0.atMs > Self.blockedWindowMs + Self.freshStateMs * 2 }
            }
            if reportsLowest {
                events += judgeHeight(&current, at: now)
            } else if !current.blocked, !current.clamped, Self.isBlocked(current, at: now) {
                // Version 1.0.1's rule, untouched by the lowest rule.
                current.blocked = true
                events.append(.limit(.blocked))
            }
        case .wrist:
            if state.activity == .orienting { current.ownLabelSeen = true }
            if state.activity == .orientClamped, current.ownLabelSeen, !current.clamped {
                current.clamped = true
                events.append(.limit(.wrist))
            }
        case .gripper(.closed):
            if state.activity == .gripperContact, !current.contact {
                current.contact = true
                gripping = true
                events.append(.contact)
            } else if !current.contact, !current.empty, let angle = state.gripperDeg, angle <= limits.emptyDeg {
                current.empty = true
                events.append(.limit(.empty))
            }
        case .gripper(.open):
            if !current.fullyOpen, let angle = state.gripperDeg, angle >= limits.openDeg {
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
    /// ending names. So a move nobody holds that the server ended for one of these was told, though nothing was
    /// emitted for it.
    public static func isToldElsewhere(_ reason: String) -> Bool {
        reason == TeleopLink.successReason || emergencyStopReasons.contains(reason) || reason == "estop_active"
    }

    /// The commanded point is far ahead and the measured arm has stood still for the whole window.
    private static func isBlocked(_ hold: Engaged, at now: Int) -> Bool {
        guard let target = hold.target, let newest = hold.samples.last, now - newest.atMs < freshStateMs,
            length(target - newest.position) >= blockedShortMeters,
            let oldest = hold.samples.last(where: { newest.atMs - $0.atMs >= blockedWindowMs })
        else { return false }
        let window = hold.samples.filter { $0.atMs >= oldest.atMs }
        return window.allSatisfy { length($0.position - oldest.position) < blockedMovedMeters }
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
        if let told = hold.lowestTold, let newest = hold.samples.last, Self.hasRisen(newest, above: told) {
            hold.lowestTold = nil
        }
        if isLowestStall(hold, at: now), let newest = hold.samples.last {
            // Both heights are kept from every stall, told or not.
            lowestSeen = min(lowestSeen ?? newest.position.z, newest.position.z)
            if let pinch = newest.pinch { lowestPinchSeen = min(lowestPinchSeen ?? pinch.z, pinch.z) }
            guard hold.lowestTold == nil else { return [] }
            hold.lowestTold = ToldHeight(
                height: newest.pinch?.z ?? newest.position.z, ofPinch: newest.pinch != nil,
                gripperZ: newest.position.z)
            // One stall, one cue: a told lowest is this hold's blocked cue as well.
            hold.blocked = true
            return [.limit(.lowest)]
        }
        guard !hold.blocked, !hold.clamped, Self.isBlockedWithoutAskingLower(hold, at: now) else { return [] }
        hold.blocked = true
        return [.limit(.blocked)]
    }

    /// The fresh measured arm stands against the operator's ask for lower. The full stall: the newest state sent at
    /// least 10 mm lower, every state of the last second at least 5 mm lower, arriving regularly, and the height
    /// within 2 mm over that second. Or the quicker one, back within 2 mm of the lowest height found of the same kind:
    /// every state of the last 0.3 s at least 5 mm lower, arriving regularly, and the height within 1 mm.
    private func isLowestStall(_ hold: Engaged, at now: Int) -> Bool {
        guard hold.target != nil, let newest = hold.samples.last, now - newest.atMs < Self.freshStateMs else {
            return false
        }
        if let below = newest.below, below >= Self.blockedShortMeters,
            let window = Self.window(of: hold.samples, ms: Self.blockedWindowMs),
            Self.asks(window, atLeast: Self.lowestSustainMeters), Self.arrivesRegularly(window),
            Self.isStill(window, within: Self.blockedMovedMeters)
        {
            return true
        }
        let height = newest.pinch?.z ?? newest.position.z
        guard let lowest = newest.pinch == nil ? lowestSeen : lowestPinchSeen,
            abs(height - lowest) <= Self.blockedMovedMeters,
            let window = Self.window(of: hold.samples, ms: Self.lowestQuickMs),
            Self.asks(window, atLeast: Self.lowestQuickShortMeters), Self.arrivesRegularly(window)
        else { return false }
        return Self.isStill(window, within: Self.lowestQuickMovedMeters)
    }

    /// Version 1.0.1's blocked stall, silent while any state of its second was sent at least 10 mm lower (the operator
    /// is asking for lower, and the lowest rule answers that), and judged only over states that arrived regularly.
    private static func isBlockedWithoutAskingLower(_ hold: Engaged, at now: Int) -> Bool {
        guard isBlocked(hold, at: now), let window = Self.window(of: hold.samples, ms: blockedWindowMs) else {
            return false
        }
        return arrivesRegularly(window) && !window.contains { $0.below.map { $0 >= blockedShortMeters } ?? false }
    }

    /// The arm has risen 10 mm above where the lowest cue was told, so the next stall is a new approach: judged on the
    /// same kind of height, or on the gripper link's when the pinch point has come or gone since.
    private static func hasRisen(_ newest: Sample, above told: ToldHeight) -> Bool {
        guard (newest.pinch != nil) == told.ofPinch else {
            return newest.position.z >= told.gripperZ + blockedShortMeters
        }
        return (newest.pinch?.z ?? newest.position.z) >= told.height + blockedShortMeters
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

    /// No two consecutive samples arrived more than `arrivalGapMs` apart.
    private static func arrivesRegularly(_ window: [Sample]) -> Bool {
        zip(window, window.dropFirst()).allSatisfy { $1.atMs - $0.atMs <= arrivalGapMs }
    }

    /// Every sample's height is less than `meters` from the oldest's: the pinch point's when every sample carries it,
    /// the gripper link's for all of them otherwise.
    private static func isStill(_ window: [Sample], within meters: Double) -> Bool {
        let pinchHeights = window.compactMap { $0.pinch?.z }
        let heights = pinchHeights.count == window.count ? pinchHeights : window.map(\.position.z)
        guard let oldest = heights.first else { return false }
        return heights.allSatisfy { abs($0 - oldest) < meters }
    }

    private static func length(_ vector: SIMD3<Double>) -> Double { (vector * vector).sum().squareRoot() }
}
