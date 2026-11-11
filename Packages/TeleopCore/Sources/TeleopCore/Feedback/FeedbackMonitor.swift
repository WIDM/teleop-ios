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

    public let limits: GripperLimits

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
        /// Where the app is sending the arm, robot base frame.
        var target: SIMD3<Double>?
        var samples: [(atMs: Int, position: SIMD3<Double>)] = []
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
                current.samples.append((now, position))
                current.samples.removeAll { now - $0.atMs > Self.blockedWindowMs + Self.freshStateMs * 2 }
            }
            if !current.blocked, !current.clamped, Self.isBlocked(current, at: now) {
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

    /// The commanded point is far ahead and the measured arm has stood still for the whole window.
    private static func isBlocked(_ hold: Engaged, at now: Int) -> Bool {
        guard let target = hold.target, let newest = hold.samples.last, now - newest.atMs < freshStateMs,
              length(target - newest.position) >= blockedShortMeters,
              let oldest = hold.samples.last(where: { newest.atMs - $0.atMs >= blockedWindowMs }) else { return false }
        let window = hold.samples.filter { $0.atMs >= oldest.atMs }
        return window.allSatisfy { length($0.position - oldest.position) < blockedMovedMeters }
    }

    private static func length(_ vector: SIMD3<Double>) -> Double { (vector * vector).sum().squareRoot() }
}
