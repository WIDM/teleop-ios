/// What the players do next.
public enum CueOutput: Equatable, Sendable {
    /// Play this pattern now, stopping whatever pattern plays.
    case haptic(Haptic)
    case stopHaptics
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
    static let logLength = 200

    private var playing: (haptic: Haptic, startedMs: Int)?
    private var lastStarted: [Haptic: Int] = [:]
    private var waitingGo: (hold: Int, sinceMs: Int)?
    private var speaking: (id: Int, sinceMs: Int)?
    private var queued: [[Phrase]] = []
    private var nextUtterance = 1
    private var refusalSpoken: [Refusal: Int] = [:]
    public private(set) var log: [CueLogEntry] = []

    public init() {}

    /// True while time alone can still produce output, so the owner should keep calling `tick`.
    public var needsTicks: Bool { waitingGo != nil || speaking != nil || !queued.isEmpty }

    /// Plays `event`. `currentHold` is the operator's hold engaged now, if any.
    public mutating func raise(_ event: FeedbackEvent, at now: Int, currentHold: Int?) -> [CueOutput] {
        let row = CueTable.row(for: event.key)
        var outputs: [CueOutput] = []
        var dropped = false
        // An emergency stop the phone announces makes a "No link. Not stopped." still waiting for the voice untrue. One
        // dropped here was never said, so the next one is no repeat.
        if case .emergencyStop = event {
            let waiting = queued.count
            queued.removeAll { $0.contains { $0.key == .notStopped } }
            if queued.count < waiting { refusalSpoken[.notStopped] = nil }
        }
        if let haptic = row.haptic {
            let (played, lost) = startHaptic(haptic, for: event, at: now, currentHold: currentHold)
            outputs += played
            dropped = lost
        }
        if let sound = row.sound { outputs.append(.sound(sound)) }
        var spoken = row.speech
        if let level = row.level {
            if case .refused(let refusal) = event, let last = refusalSpoken[refusal], now - last < Self.refusalRepeatMs
            {
                spoken = []
            } else if let speech = speak(CueTable.phrases(for: event), level: level, at: now) {
                outputs.append(speech)
                if case .refused(let refusal) = event { refusalSpoken[refusal] = now }
            } else if level == .p4 {
                spoken = []
                dropped = true
            } else if case .refused(let refusal) = event {
                refusalSpoken[refusal] = now
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
        if let current = speaking, now - current.sinceMs >= Self.speechTimeoutMs { speaking = nil }
        if speaking == nil, !queued.isEmpty {
            let next = queued.removeFirst()
            outputs.append(startSpeaking(next, interrupt: false, at: now))
        }
        return outputs
    }

    /// The utterance `id` ended, spoken through or cut off.
    public mutating func speechFinished(id: Int, at now: Int) -> [CueOutput] {
        guard speaking?.id == id else { return [] }
        speaking = nil
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

    private mutating func speak(_ phrases: [Phrase], level: SpeechLevel, at now: Int) -> CueOutput? {
        switch level {
        case .p1:
            return startSpeaking(phrases, interrupt: true, at: now)
        case .p2:
            guard speaking == nil else {
                queued.append(phrases)
                return nil
            }
            return startSpeaking(phrases, interrupt: false, at: now)
        case .p4:
            guard speaking == nil else { return nil }
            return startSpeaking(phrases, interrupt: false, at: now)
        }
    }

    private mutating func startSpeaking(_ phrases: [Phrase], interrupt: Bool, at now: Int) -> CueOutput {
        let id = nextUtterance
        nextUtterance += 1
        speaking = (id, now)
        return .speak(phrases, interrupt: interrupt, id: id)
    }

    private mutating func record(_ entry: CueLogEntry) {
        log.append(entry)
        if log.count > Self.logLength { log.removeFirst(log.count - Self.logLength) }
    }
}
