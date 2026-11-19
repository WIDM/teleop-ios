/// What the players do next.
public enum CueOutput: Equatable, Sendable {
    /// Play this pattern now, stopping whatever pattern plays.
    case haptic(Haptic)
    case stopHaptics
    case stopSpeech(id: Int)
    case sound(Sound)
    /// Speak these phrases as one utterance, named `id` so its end can be reported. `interrupt`: stop current
    /// speech first.
    case speak([Phrase], interrupt: Bool, id: Int)
}

/// One cue as it was decided, for the developer log and for tests (§5.9).
public struct CueLogEntry: Equatable, Sendable {
    public let atMs: Int
    public let event: CueKey
    public let haptic: Haptic?
    public let sound: Sound?
    public let speech: [SpeechKey]
    /// The haptic lost to a higher cue or to its own repeat, or the speech was dropped.
    public let dropped: Bool
}

/// Decides which cue plays when two coincide (§5.4). Pure: time is passed in, nothing is played here.
///
/// Haptics are one channel, ALARM > LETGO > NO > GRIP > END > ON TARGET > GO. A higher cue pre-empts a lower one
/// that plays; a lower one arriving while a higher one plays is dropped. The same pattern never starts twice within
/// `repeatMs`. GO is never dropped for either reason: it waits until the channel is free and its own repeat gap has
/// passed (at most `goWaitMaxMs`) and plays then, if its own hold is still the one engaged. Speech follows its
/// level; sounds always play at once.
public struct CueScheduler {
    public static let goWaitMaxMs = 400
    public static let repeatMs = 300
    /// A refusal's reason is spoken at most this often.
    public static let refusalRepeatMs = 3000
    /// An utterance whose end was never reported counts as finished after this long.
    static let speechTimeoutMs = 15_000
    public static let readinessMaxAgeMs = 2000
    static let logLength = 200

    private var playing: (haptic: Haptic, startedMs: Int)?
    private var lastStarted: [Haptic: Int] = [:]
    private var waitingGo: (hold: Int, sinceMs: Int)?
    private struct PendingSpeech {
        let event: CueKey
        let phrases: [Phrase]
        let decidedAtMs: Int
    }

    private var speaking: (id: Int, sinceMs: Int, event: CueKey, decidedAtMs: Int)?
    private var queued: [PendingSpeech] = []
    private var ready = true
    private var nextUtterance = 1
    private var refusalSpoken: [Refusal: Int] = [:]
    public private(set) var log: [CueLogEntry] = []

    public init() {}

    /// True while time alone can still produce output, so the owner should keep calling `tick`.
    public var needsTicks: Bool { waitingGo != nil || speaking != nil || !queued.isEmpty }

    public mutating func updateReadiness(_ ready: Bool, at now: Int) -> [CueOutput] {
        self.ready = ready
        guard !ready else { return [] }
        discardExpiredReadiness(at: now)
        guard let current = speaking, current.event == .ready else { return [] }
        speaking = nil
        record(CueLogEntry(atMs: now, event: .ready, haptic: nil, sound: nil, speech: [], dropped: true))
        return [.stopSpeech(id: current.id)]
    }

    /// Plays `event`. `currentHold` is the operator's hold engaged now, if any.
    public mutating func raise(_ event: FeedbackEvent, at now: Int, currentHold: Int?) -> [CueOutput] {
        let row = CueTable.row(for: event.key)
        var outputs: [CueOutput] = []
        switch event {
        case .emergencyStop, .linkLost: outputs += updateReadiness(false, at: now)
        default: break
        }
        var dropped = false
        // An emergency stop the phone announces makes a "No link. Not stopped." still waiting for the voice untrue. One
        // dropped here was never said, so the next one is no repeat.
        if case .emergencyStop = event {
            let waiting = queued.count
            queued.removeAll { $0.phrases.contains { $0.key == .notStopped } }
            if queued.count < waiting { refusalSpoken[.notStopped] = nil }
        }
        // A "Locked on." still waiting for the voice would follow the alarm or "Link lost." about a follow that has
        // ended. The latch was felt at its moment, and a waiting ending is still said, so nothing goes untold.
        switch event {
        case .emergencyStop, .linkLost:
            outputs += invalidateLatch(at: now)
        case .drive(let drive) where drive != .latched:
            outputs += invalidateLatch(at: now)
        default: break
        }
        if let haptic = row.haptic {
            let (played, lost) = startHaptic(haptic, for: event, at: now, currentHold: currentHold)
            outputs += played
            dropped = lost
        }
        if let sound = row.sound { outputs.append(.sound(sound)) }
        var spoken = row.speech
        let repeatsAs: Refusal?
        switch event {
        case .refused(let refusal): repeatsAs = refusal
        case .letGo(.slowLink): repeatsAs = .slowLink
        default: repeatsAs = nil
        }
        if let level = row.level {
            if event.key == .ready, !ready {
                spoken = []
                dropped = true
            } else if case .refused(let refusal) = event, let last = refusalSpoken[refusal],
                now - last < Self.refusalRepeatMs
            {
                spoken = []
            } else if let speech = speak(
                PendingSpeech(event: event.key, phrases: CueTable.phrases(for: event), decidedAtMs: now), level: level,
                at: now)
            {
                outputs.append(speech)
                if let repeatsAs { refusalSpoken[repeatsAs] = now }
            } else if level == .p4 {
                spoken = []
                dropped = true
            } else if let repeatsAs {
                refusalSpoken[repeatsAs] = now
            }
        }
        record(
            CueLogEntry(
                atMs: now, event: event.key, haptic: row.haptic, sound: row.sound, speech: spoken, dropped: dropped))
        return outputs
    }

    /// Plays a waiting GO when it is due, and the next queued phrase once the voice is free.
    public mutating func tick(at now: Int, currentHold: Int?) -> [CueOutput] {
        expire(at: now)
        var outputs: [CueOutput] = []
        if let waiting = waitingGo {
            if waiting.hold != currentHold {
                waitingGo = nil
                record(CueLogEntry(atMs: now, event: .holdLive, haptic: .go, sound: nil, speech: [], dropped: true))
            } else if goIsFree(at: now) || now - waiting.sinceMs >= Self.goWaitMaxMs {
                waitingGo = nil
                outputs.append(play(.go, at: now))
            }
        }
        if let current = speaking, now - current.sinceMs >= Self.speechTimeoutMs {
            speaking = nil
            outputs.append(.stopSpeech(id: current.id))
        }
        discardExpiredReadiness(at: now)
        if speaking == nil, !queued.isEmpty {
            let next = queued.removeFirst()
            outputs.append(startSpeaking(next, interrupt: false, at: now))
        }
        return outputs
    }

    public mutating func speechWillStart(id: Int, at now: Int) -> [CueOutput] {
        guard let current = speaking, current.id == id, current.event == .ready,
            !ready || now - current.decidedAtMs >= Self.readinessMaxAgeMs
        else { return [] }
        speaking = nil
        record(CueLogEntry(atMs: now, event: .ready, haptic: nil, sound: nil, speech: [], dropped: true))
        return [.stopSpeech(id: id)]
    }

    /// The utterance `id` ended, spoken through or cut off.
    public mutating func speechFinished(id: Int, at now: Int) -> [CueOutput] {
        guard speaking?.id == id else { return [] }
        speaking = nil
        discardExpiredReadiness(at: now)
        guard !queued.isEmpty else { return [] }
        return [startSpeaking(queued.removeFirst(), interrupt: false, at: now)]
    }

    /// Stops the pattern that plays and forgets a waiting GO, as releasing an emergency stop does.
    public mutating func stopHaptics() -> [CueOutput] {
        playing = nil
        waitingGo = nil
        return [.stopHaptics]
    }

    // MARK: Haptics

    private mutating func startHaptic(_ haptic: Haptic, for event: FeedbackEvent, at now: Int, currentHold: Int?) -> (
        [CueOutput], Bool
    ) {
        expire(at: now)
        if case .holdLive(let hold) = event {
            guard hold == currentHold else { return ([], true) }
            guard goIsFree(at: now) else {
                waitingGo = (hold, now)
                return ([], false)
            }
            return ([play(.go, at: now)], false)
        }
        if let last = lastStarted[haptic], now - last < Self.repeatMs { return ([], true) }
        if let current = playing, haptic.priority <= current.haptic.priority { return ([], true) }
        return ([play(haptic, at: now)], false)
    }

    /// Nothing plays (GO is the lowest cue) and the last GO started at least `repeatMs` ago.
    private func goIsFree(at now: Int) -> Bool {
        guard playing == nil else { return false }
        guard let last = lastStarted[.go] else { return true }
        return now - last >= Self.repeatMs
    }

    private mutating func play(_ haptic: Haptic, at now: Int) -> CueOutput {
        playing = (haptic, now)
        lastStarted[haptic] = now
        return .haptic(haptic)
    }

    private mutating func expire(at now: Int) {
        if let current = playing, now - current.startedMs >= current.haptic.durationMs { playing = nil }
    }

    // MARK: Speech

    private mutating func speak(_ pending: PendingSpeech, level: SpeechLevel, at now: Int) -> CueOutput? {
        switch level {
        case .p1:
            return startSpeaking(pending, interrupt: true, at: now)
        case .p2:
            guard speaking == nil else {
                queued.append(pending)
                return nil
            }
            return startSpeaking(pending, interrupt: false, at: now)
        case .p4:
            guard speaking == nil else { return nil }
            return startSpeaking(pending, interrupt: false, at: now)
        }
    }

    private mutating func startSpeaking(_ pending: PendingSpeech, interrupt: Bool, at now: Int) -> CueOutput {
        let id = nextUtterance
        nextUtterance += 1
        speaking = (id, now, pending.event, pending.decidedAtMs)
        return .speak(pending.phrases, interrupt: interrupt, id: id)
    }

    private mutating func invalidateLatch(at now: Int) -> [CueOutput] {
        let count = queued.count
        queued.removeAll { $0.event == .drive(.latched) }
        if count != queued.count {
            record(CueLogEntry(atMs: now, event: .drive(.latched), haptic: nil, sound: nil, speech: [], dropped: true))
        }
        guard let current = speaking, current.event == .drive(.latched) else { return [] }
        speaking = nil
        return [.stopSpeech(id: current.id)]
    }

    private mutating func discardExpiredReadiness(at now: Int) {
        let dropped = queued.filter { $0.event == .ready && (!ready || now - $0.decidedAtMs >= Self.readinessMaxAgeMs) }
        queued.removeAll { $0.event == .ready && (!ready || now - $0.decidedAtMs >= Self.readinessMaxAgeMs) }
        for entry in dropped {
            record(CueLogEntry(atMs: now, event: entry.event, haptic: nil, sound: nil, speech: [], dropped: true))
        }
    }

    private mutating func record(_ entry: CueLogEntry) {
        log.append(entry)
        if log.count > Self.logLength { log.removeFirst(log.count - Self.logLength) }
    }
}
