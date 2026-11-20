import Foundation

/// The fields of one `state` that tell whether the simulation behind the server still runs. Kept apart from
/// `ServerState` because they change with every message, and a state that says nothing new must stay equal to the one
/// before. A field the server did not send is nil.
public struct StateHealth: Equatable, Sendable {
    /// `timing.captured_monotonic_ns`: when the server last wrote the state, on its own monotonic clock. The
    /// simulation loop writes it on every pass, about 60 times a second.
    public var capturedNs: UInt64?
    /// `timing.sent_monotonic_ns`: when this copy left the server, on the same clock.
    public var sentNs: UInt64?
    /// `sim_stalled`: the server's own judgement that its simulation loop has stopped. Older servers do not send it.
    public var simStalled: Bool?
    /// `loop_age_ms`: how long since the loop's last pass, as the server measured it. Older servers do not send it.
    public var loopAgeMs: Double?
    /// `ik` is `resetting`: the scene resets, and the loop writes no state for seconds while it does.
    public var resetting: Bool

    public init(
        capturedNs: UInt64? = nil, sentNs: UInt64? = nil, simStalled: Bool? = nil, loopAgeMs: Double? = nil,
        resetting: Bool = false
    ) {
        self.capturedNs = capturedNs
        self.sentNs = sentNs
        self.simStalled = simStalled
        self.loopAgeMs = loopAgeMs
        self.resetting = resetting
    }

    /// Reads a `state` payload. Fields of the wrong type count as missing.
    public init(payload: [String: Any]) {
        let timing = payload["timing"] as? [String: Any]
        capturedNs = Self.unsigned(timing?["captured_monotonic_ns"])
        sentNs = Self.unsigned(timing?["sent_monotonic_ns"])
        simStalled = Self.flag(payload["sim_stalled"])
        loopAgeMs = (payload["loop_age_ms"] as? NSNumber).flatMap {
            CFGetTypeID($0) == CFBooleanGetTypeID() || !$0.doubleValue.isFinite ? nil : $0.doubleValue
        }
        resetting = payload["ik"] as? String == "resetting"
    }

    /// How long before this copy was sent the state was written, milliseconds; nil without both times, or when they
    /// are out of order.
    public var ageMs: Int? {
        guard let capturedNs, let sentNs, sentNs >= capturedNs else { return nil }
        return Int((sentNs - capturedNs) / 1_000_000)
    }

    private static func flag(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func unsigned(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        guard let value = UInt64(number.stringValue), value <= UInt64(Int64.max) else { return nil }
        return value
    }
}

/// Whether the simulation loop behind the server still runs, in two levels. Pure: every message and the time are
/// passed in, and nothing is read from a clock.
///
/// The loop pauses for seconds on its own and recovers (measured: 5.1 s during a scene reset, 4.6 s while stopped,
/// 0.8 s during a move, and in a 30-minute run pauses of 4.5 to 8.7 s that all recovered), so a sign of a stopped loop first makes it **paused**: nothing new is sent and the stop is
/// kept, quietly, until it runs again. Only a pause that lasts `notRespondingMs` makes it **not responding**, the one
/// level the operator is told to restart the server at.
///
/// Paused is entered by the first of these signs (`Trigger`):
///
/// | Trigger            | Input                    | Holds when                                                        |
/// |--------------------|--------------------------|-------------------------------------------------------------------|
/// | `serverFlag`       | `state`                  | the state says `sim_stalled` true                                 |
/// | `serverRefusal`    | `refused`                | any request is refused `sim_stalled`                              |
/// | `frozenTime`       | `state`                  | `staleStates` states in a row are each older than `staleAgeMs`    |
/// |                    |                          | when sent and older than the one before                           |
/// | `busy`             | `refused`, `tick`        | moves have been refused `busy` for over `busyMs`, no stop answered |
/// | `stopUnanswered`   | `stopSent`, `tick`       | a stop this phone sent has had no final answer for `stopAnswerMs` |
/// | `releaseRefused`   | `refused`                | a stop release is refused `estop_not_frozen` while a sign holds:  |
/// |                    |                          | the newest state is older than `staleAgeMs`, a move was refused   |
/// |                    |                          | busy since the last stop answer, or a stop has waited for its     |
/// |                    |                          | answer longer than `TeleopLink.finishWaitMs`                      |
///
/// Not responding is reached when paused has lasted `notRespondingMs` without clearing, or at once when a state says
/// `sim_stalled` with `loop_age_ms` of at least `notRespondingMs`.
///
/// Neither level is entered during a scene reset: while the newest state says `resetting`, or after a reset this phone
/// asked for (`resetRequested`), for at most `resetAllowanceMs` either way, so a reset that never ends is still found.
///
/// The last four triggers are the app's own judgement. They count only once a state with its timing has come on this
/// connection, because only such states can ever clear the level again: from a server without timing the app would
/// otherwise keep the operator from the arm until he reconnects.
///
/// Both levels clear on `freshStates` healthy states in a row, judged by what the state carries, so every way in has a
/// way out with the same information that got it in:
///
/// | The state carries          | It is healthy when                                                          |
/// |----------------------------|-----------------------------------------------------------------------------|
/// | its timing                 | its captured time moved on, it is younger than `staleAgeMs` when sent, and  |
/// |                            | it does not say `sim_stalled`                                               |
/// | `sim_stalled`, no timing   | it says false, with no `loop_age_ms` or one of at most `staleAgeMs`         |
/// | neither                    | no state on this connection ever carried either: a refusal is then the only |
/// |                            | sign there can be, and a state not saying so is all the server can tell     |
///
/// Every healthy state with timing also drops the busy answers and unanswered stops gathered so far: the loop runs, so
/// a busy answer is another client's hold and a missing answer is only late.
///
/// A state with timing written before the newest one seen (the other connection's, or one delivered late) says nothing
/// new and is passed over whole: it sets no sign and no reset.
///
/// Time the app spends in the background does not count toward any wait, and a state or refusal heard then is not read:
/// on its return the waits go on from where they stood, and the states that come then decide.
public struct SimStallDetector: Equatable, Sendable {
    /// A state older than this when sent was not written by a running loop: it writes one about every 17 ms.
    public static let staleAgeMs = 2000
    /// Stale states in a row, each older than the one before, that make the frozen-time sign.
    public static let staleStates = 3
    /// How long moves may be refused busy, with no stop answered, before the loop counts as paused.
    public static let busyMs = 3000
    /// How long a stop's final answer may be missing.
    public static let stopAnswerMs = 3000
    /// Fresh states in a row that clear either level.
    public static let freshStates = 3
    /// How long paused may last before the simulator counts as not responding.
    public static let notRespondingMs = 15_000
    /// How long a scene reset may take before its silence counts.
    public static let resetAllowanceMs = 12_000

    public enum Level: Int, Comparable, Sendable {
        case running
        /// A sign of a stopped loop: nothing new is sent, the stop is kept, and nothing is spoken.
        case paused
        /// Paused for `notRespondingMs`: the operator is told to restart the server.
        case notResponding

        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    /// Why paused was entered.
    public enum Trigger: String, Equatable, Sendable {
        case serverFlag
        case serverRefusal
        case frozenTime
        case busy
        case stopUnanswered
        case releaseRefused
    }

    /// Everything the decision reads.
    public enum Input: Equatable, Sendable {
        /// A `state` arrived on either connection.
        case state(StateHealth)
        /// The server refused `request` (the wire type: `pose_start`, `estop_reset`, ...) with `reason`.
        case refused(request: String, reason: String)
        /// This phone sent the stop of the control whose start had seq `start`.
        case stopSent(start: Int)
        /// The final answer for the control whose start had seq `start` arrived.
        case stopAnswered(start: Int)
        /// This phone asked for a scene reset.
        case resetRequested
        /// Time passed.
        case tick
        /// The app left the foreground: its timers stop, and nothing it hears meanwhile is read.
        case background
        /// The app is back in the foreground.
        case foreground
    }

    public private(set) var level = Level.running
    /// What entered paused; nil while running.
    public private(set) var trigger: Trigger?
    /// Paused or not responding: nothing new may be sent.
    public var stalled: Bool { level != .running }
    /// When paused was entered.
    private var pausedSinceMs: Int?
    /// A state with both its times has come: the app may judge by time.
    private var timed = false
    /// A state saying `sim_stalled`, either way, has come.
    private var flagged = false
    /// Since when the app is in the background; nil in the foreground.
    private var backgroundSinceMs: Int?
    private var newestCapturedNs: UInt64?
    private var newestAgeMs: Int?
    private var staleRun = 0
    private var freshRun = 0
    /// When the first `busy` since the last stop answer or fresh state came.
    private var busySinceMs: Int?
    /// Stops this phone sent with no final answer yet, by the seq of the start they ended, with when they went out.
    private var unansweredStops: [Int: Int] = [:]
    /// Since when the newest states say `resetting`; nil when the newest does not.
    private var resettingSinceMs: Int?
    private var resetRequestedAtMs: Int?

    public init() {}

    /// Takes one input at `now` (milliseconds). True when the level changed.
    @discardableResult
    public mutating func observe(_ input: Input, at now: Int) -> Bool {
        let before = level
        // A message heard in the background is not read: nothing may raise the level while the app is away, and after
        // the return the states that come then decide.
        let away = backgroundSinceMs != nil
        switch input {
        case .state(let health):
            if !away { observeState(health, at: now) }
        case .refused(let request, let reason):
            guard !away else { break }
            if reason == "sim_stalled" { pause(.serverRefusal, at: now) }
            if reason == "busy", busySinceMs == nil { busySinceMs = now }
            if request == "estop_reset", reason == "estop_not_frozen", timed, signHolds(at: now) {
                pause(.releaseRefused, at: now)
            }
        case .stopSent(let start):
            if unansweredStops[start] == nil { unansweredStops[start] = now }
            // A phone that never hears its answers must not grow this without end.
            if unansweredStops.count > 16, let oldest = unansweredStops.min(by: { $0.value < $1.value }) {
                unansweredStops[oldest.key] = nil
            }
        case .stopAnswered(let start):
            if unansweredStops.removeValue(forKey: start) != nil { busySinceMs = nil }
        case .resetRequested:
            resetRequestedAtMs = now
        case .tick:
            break
        case .background:
            if backgroundSinceMs == nil { backgroundSinceMs = now }
        case .foreground:
            if let since = backgroundSinceMs { carryWaits(by: now - since) }
            backgroundSinceMs = nil
        }
        if resetting(at: now) {
            // A reset is silent for seconds: nothing gathered during it is a sign.
            staleRun = 0
            busySinceMs = nil
            unansweredStops = [:]
        }
        checkTime(at: now)
        return level != before
    }

    private mutating func observeState(_ health: StateHealth, at now: Int) {
        let timing = health.capturedNs.flatMap { captured in health.ageMs.map { (captured, $0) } }
        // A state the other connection already overtook, or one delivered late, says nothing new.
        if let (captured, _) = timing, let newest = newestCapturedNs, captured < newest { return }
        if health.resetting {
            if resettingSinceMs == nil { resettingSinceMs = now }
        } else {
            resettingSinceMs = nil
        }
        if health.simStalled != nil { flagged = true }
        if health.simStalled == true {
            freshRun = 0
            pause(.serverFlag, at: now)
            if let age = health.loopAgeMs, age >= Double(Self.notRespondingMs), !resetting(at: now) {
                level = .notResponding
            }
        }
        if let (captured, age) = timing {
            timed = true
            let advanced = newestCapturedNs.map { captured > $0 } ?? false
            if age > Self.staleAgeMs {
                staleRun = newestAgeMs.map { age > $0 } == true ? staleRun + 1 : 1
                freshRun = 0
            } else {
                staleRun = 0
                // The same state again, as both connections may carry it, neither counts nor breaks the run.
                if advanced, health.simStalled != true {
                    freshRun += 1
                    busySinceMs = nil
                    unansweredStops = [:]
                }
            }
            newestCapturedNs = captured
            newestAgeMs = age
            if staleRun >= Self.staleStates { pause(.frozenTime, at: now) }
        } else if health.simStalled == false {
            if let loopAge = health.loopAgeMs, loopAge > Double(Self.staleAgeMs) {
                freshRun = 0
            } else {
                freshRun += 1
            }
        } else if health.simStalled == nil, !timed, !flagged {
            freshRun += 1
        }
        if level != .running, freshRun >= Self.freshStates {
            level = .running
            trigger = nil
            pausedSinceMs = nil
            staleRun = 0
        }
    }

    private mutating func checkTime(at now: Int) {
        // In the background nothing is heard, so no wait may run out.
        guard backgroundSinceMs == nil else { return }
        if timed {
            if let since = busySinceMs, now - since > Self.busyMs { pause(.busy, at: now) }
            if let oldest = unansweredStops.values.min(), now - oldest >= Self.stopAnswerMs {
                pause(.stopUnanswered, at: now)
            }
        }
        if level == .paused, let since = pausedSinceMs, now - since >= Self.notRespondingMs { level = .notResponding }
    }

    /// The app was away for `ms`: every wait goes on from where it stood when the app left.
    private mutating func carryWaits(by ms: Int) {
        guard ms > 0 else { return }
        pausedSinceMs = pausedSinceMs.map { $0 + ms }
        busySinceMs = busySinceMs.map { $0 + ms }
        unansweredStops = unansweredStops.mapValues { $0 + ms }
    }

    /// A scene reset is under way, within its allowance.
    private func resetting(at now: Int) -> Bool {
        let since = [resettingSinceMs, resetRequestedAtMs].compactMap { $0 }
        return since.contains { now - $0 < Self.resetAllowanceMs }
    }

    /// Another sign of a stopped loop is there, short of pausing by itself.
    private func signHolds(at now: Int) -> Bool {
        if let age = newestAgeMs, age > Self.staleAgeMs { return true }
        if busySinceMs != nil { return true }
        if let oldest = unansweredStops.values.min(), now - oldest > TeleopLink.finishWaitMs { return true }
        return false
    }

    private mutating func pause(_ why: Trigger, at now: Int) {
        guard level == .running, !resetting(at: now) else { return }
        level = .paused
        trigger = why
        pausedSinceMs = now
        freshRun = 0
    }
}
