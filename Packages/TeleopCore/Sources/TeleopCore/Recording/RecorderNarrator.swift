/// What a screen shows of the server's recorder.
public struct RecorderDisplay: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// No server yet, or a server whose state has no `rec` key.
        case unknown
        /// The server runs without a recorder.
        case notRecording
        case armed
        case capturing
        /// After a success, until the automatic reset arms the recorder again. A reset is refused meanwhile.
        case waiting
        /// Off outside the success display, as after an emergency stop: moving now records nothing until a reset.
        case off
    }

    public var mode: Mode
    /// Demonstrations in the session file, earlier server runs included.
    public var saved: Int?
    /// Takes thrown away since the server started.
    public var discarded: Int?
    /// Length of the take being captured, or of the one just saved, in simulated seconds.
    public var secondsCaptured: Double?

    public init(mode: Mode, saved: Int? = nil, discarded: Int? = nil, secondsCaptured: Double? = nil) {
        self.mode = mode
        self.saved = saved
        self.discarded = discarded
        self.secondsCaptured = secondsCaptured
    }

    public static let unknown = RecorderDisplay(mode: .unknown)
}

/// Narrates the recording session from successive states (interaction specification §6.2, §6.3, §6.5, §6.7,
/// §6.10). Pure: time is passed in, in milliseconds.
///
/// Counters are compared, not edges: a save or a discard is told whenever `rec_saved` or `rec_discarded` has
/// risen since the last state seen, so a state missed during a link drop still gives the right result. A discard
/// an emergency stop or an unsaved success already speaks of is not told twice.
public struct RecorderNarrator {
    /// A success with no rise in `rec_saved` this long after it was not saved.
    public static let notSavedWaitMs = 2000
    /// The recorder takes one sample every second physics step, 30 a simulated second.
    public static let samplesPerSecond = 30.0

    public private(set) var display = RecorderDisplay.unknown
    /// The newest recorder fields; nil while the server is unknown.
    public private(set) var recorder: RecorderStatus?

    /// The server run of the newest connection.
    private var session: String?
    /// Set by `welcomed`, cleared by the first state after it.
    private var greeting: (reconnect: Bool, newRun: Bool)?
    /// The newest state seen, kept across a link drop for the comparison after it.
    private var last: ServerState?
    /// The recorder label in the newest state without an emergency stop: what the stop interrupted.
    private var labelBeforeStop: RecorderLabel?
    private var stopNoted = false
    private var absorbDiscard = false
    private var pendingSuccess: (sinceMs: Int, saved: Int)?
    /// A connection or a new episode began while the state did not read ready: "Ready." comes with the first state
    /// that does. The real server sends the state right after `ok scene_reset` with the new episode but the
    /// recorder fields of the take it just threw away.
    private var readyOwed = false
    private var notRecordingSaid = false
    private var connections = 0
    /// The link was lost since the last welcome: the next one is a reconnect, not the operator's own.
    private var lost = false

    public init() {}

    /// True when an emergency stop now throws away a take: one was being captured when it came.
    public var stopDiscardsTake: Bool { labelBeforeStop == .capturing }

    /// A control connection said `welcome`. The first state after it is compared with the last one before.
    public mutating func welcomed(session: String?) {
        connections += 1
        greeting = (lost, connections > 1 && session != self.session)
        lost = false
        self.session = session
    }

    /// The control connection dropped. A success still waiting for its save is judged after the reconnect.
    public mutating func linkLost() {
        lost = true
    }

    /// The app learned of an emergency stop before any state showed it, as STOP on the phone does.
    public mutating func emergencyStopLearned() {
        noteStop()
    }

    /// A `state` from either connection. `moving`: a hold is engaged.
    public mutating func observe(_ state: ServerState, moving: Bool, at now: Int) -> [FeedbackEvent] {
        if state.estop {
            noteStop()
            // Releasing the stop, or the reset that clears it, says "Ready." itself.
            readyOwed = false
        }
        var events: [FeedbackEvent] = []
        if let greeting {
            self.greeting = nil
            events += greet(state, reconnect: greeting.reconnect, newRun: greeting.newRun)
        } else if let before = last {
            events += compare(before, state, at: now)
        }
        if !state.estop {
            stopNoted = false
            labelBeforeStop = state.recorder?.label
        }
        if let label = state.recorder?.label, label == .armed || label == .capturing { notRecordingSaid = false }
        if moving, state.recorder?.label == .off, !state.estop, !state.simBusy, pendingSuccess == nil, !notRecordingSaid
        {
            notRecordingSaid = true
            events.append(.notRecording)
        }
        last = state
        recorder = state.recorder
        display = Self.display(for: state, waiting: pendingSuccess != nil)
        return events
    }

    /// A success whose save never came.
    public mutating func tick(at now: Int) -> [FeedbackEvent] {
        guard let pending = pendingSuccess, now - pending.sinceMs >= Self.notSavedWaitMs else { return [] }
        pendingSuccess = nil
        if let last { display = Self.display(for: last, waiting: false) }
        return [.successNotSaved]
    }

    private mutating func noteStop() {
        guard !stopNoted else { return }
        stopNoted = true
        // The stop speaks of the discarded take itself.
        if labelBeforeStop == .capturing { absorbDiscard = true }
    }

    /// The first state on a new connection.
    private mutating func greet(_ state: ServerState, reconnect: Bool, newRun: Bool) -> [FeedbackEvent] {
        let success = pendingSuccess
        pendingSuccess = nil
        readyOwed = false
        let sameRun = reconnect && !newRun
        let before = sameRun ? last?.recorder : nil
        // An emergency stop found on arrival, or one the app is sending now, is announced by its own event,
        // which says enough.
        guard !state.estop, !stopNoted else {
            // The stop's own discard may already be counted here; it must not swallow a later one.
            if let before, let now = state.recorder, now.discarded > before.discarded { absorbDiscard = false }
            if !sameRun { absorbDiscard = false }
            return []
        }
        var events: [FeedbackEvent] = []
        if reconnect { events.append(.reconnected) }
        if let before, let now = state.recorder {
            var discarded = now.discarded - before.discarded - (absorbDiscard ? 1 : 0)
            absorbDiscard = false
            if now.saved > before.saved {
                events.append(.offlineSaved(now.saved - before.saved))
            } else if success != nil {
                events.append(.successNotSaved)
                // A take too short to save was discarded at the success; "Success, but not saved." covers it.
                discarded -= 1
            }
            if discarded > 0 { events.append(.offlineDiscarded(discarded)) }
            // Only the same episode is the take that continues; a new one owes "Ready." (§6.7).
            if now.label == .capturing, state.episode == last?.episode {
                events.append(.takeContinues)
                return events
            }
        } else {
            absorbDiscard = false
            if newRun { events.append(.serverRestarted) }
            if let recorder = state.recorder, recorder.records {
                events.append(.recordingSession(saved: recorder.saved))
            }
        }
        if Self.ready(state) {
            events.append(.ready)
        } else {
            readyOwed = true
        }
        return events
    }

    /// The next state on the same connection.
    private mutating func compare(_ before: ServerState, _ state: ServerState, at now: Int) -> [FeedbackEvent] {
        var events: [FeedbackEvent] = []
        let saved = (state.recorder?.saved ?? 0) - (before.recorder?.saved ?? 0)
        if before.recorder != nil, let recorder = state.recorder, saved > 0 {
            pendingSuccess = nil
            events.append(.takeSaved(count: recorder.saved))
        }
        if state.taskSuccess == true, before.taskSuccess != true {
            if let recorder = state.recorder, recorder.records {
                // Saved in the same state, or wait for the save.
                if saved <= 0 { pendingSuccess = (now, recorder.saved) }
            } else {
                events.append(.taskSuccess)
            }
        }
        let discarded =
            before.recorder != nil && state.recorder != nil
            && (state.recorder?.discarded ?? 0) > (before.recorder?.discarded ?? 0)
        let newEpisode = state.episode != nil && before.episode != nil && state.episode != before.episode
        if pendingSuccess != nil, discarded || newEpisode {
            // The save comes with the success or not at all. A discard (a take too short to save) or the automatic
            // reset settles it before the 2 s are up, and "Success, but not saved." must come before "Ready.".
            // It also covers the discard.
            pendingSuccess = nil
            events.append(.successNotSaved)
        } else if discarded {
            if absorbDiscard {
                absorbDiscard = false
            } else {
                events.append(.takeDiscarded)
            }
        }
        if newEpisode {
            notRecordingSaid = false
            readyOwed = true
        }
        if readyOwed, Self.ready(state) {
            readyOwed = false
            events.append(.ready)
        }
        return events
    }

    /// Connected, not stopped, the simulator taking commands, and no take of someone else's being captured.
    private static func ready(_ state: ServerState) -> Bool {
        !state.estop && !state.simBusy && state.recorder?.label != .capturing
    }

    private static func display(for state: ServerState, waiting: Bool) -> RecorderDisplay {
        guard let recorder = state.recorder else { return .unknown }
        let mode: RecorderDisplay.Mode
        switch recorder.label {
        case .none: mode = .notRecording
        case .armed: mode = .armed
        case .capturing: mode = .capturing
        case .off: mode = state.simBusy || waiting ? .waiting : .off
        }
        guard recorder.records else { return RecorderDisplay(mode: mode) }
        return RecorderDisplay(
            mode: mode, saved: recorder.saved, discarded: recorder.discarded,
            secondsCaptured: recorder.samples > 0 ? Double(recorder.samples) / samplesPerSecond : nil
        )
    }
}
