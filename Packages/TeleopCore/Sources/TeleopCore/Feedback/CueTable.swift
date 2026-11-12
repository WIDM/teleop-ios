/// The three sounds (§5.2). Everything rarer than about once a minute is a sound and speech.
public enum Sound: String, CaseIterable, Sendable {
    /// Two rising notes.
    case saved
    /// Two falling notes: a take discarded, or a success not saved.
    case discarded
    /// Three low pulses.
    case linkLost
}

/// How a phrase competes for the one voice (§5.4). The voice dialogue's level, P3, is not used in version 1.
public enum SpeechLevel: Int, Comparable, Sendable {
    /// Stops current speech at once and speaks: emergency stop, link lost.
    case p1 = 1
    /// Queued and never dropped.
    case p2 = 2
    /// Spoken at once, during a hold too, or dropped if another phrase is playing.
    case p4 = 4

    public static func < (a: SpeechLevel, b: SpeechLevel) -> Bool { a.rawValue < b.rawValue }
}

/// A spoken phrase's key in the app's `Speech` string table (§8.2), which holds English and Traditional Chinese.
public enum SpeechKey: String, CaseIterable, Sendable {
    case ready = "say.ready"
    case linkLost = "say.link_lost"
    case reconnected = "say.reconnected"
    case serverRestarted = "say.server_restarted"
    case offlineSaved = "say.offline_saved"
    case offlineDiscarded = "say.offline_discarded"
    case takeContinues = "say.take_continues"
    case estop = "say.estop"
    case causeButton = "say.cause.button"
    case causeLink = "say.cause.link"
    case causeBehind = "say.cause.behind"
    case causeOnConnect = "say.cause.on_connect"
    case causeOther = "say.cause.other"
    case resetPrompt = "say.reset_prompt"
    case notReset = "say.not_reset"
    case recordingSession = "say.rec_session"
    case savedCount = "say.saved_count"
    case takeDiscarded = "say.take_discarded"
    case savedN = "say.saved_n"
    case success = "say.success"
    case successNotSaved = "say.success_not_saved"
    case notRecording = "say.not_recording"
    case stopped = "say.stopped"
    case wait = "say.wait"
    case noLink = "say.reason.no_link"
    case notStopped = "say.reason.not_stopped"
    case notTracking = "say.reason.not_tracking"
    case posture = "say.reason.posture"
    case slowLink = "say.reason.slow_link"
    case letGoFirst = "say.let_go_first"
    case tooFast = "say.letgo.too_fast"
    case lostTracking = "say.letgo.tracking"
    case noAnswer = "say.letgo.no_answer"
    case linkHiccup = "say.letgo.link_hiccup"
    case refusedMove = "say.letgo.refused"
    case blocked = "say.blocked"
    case empty = "say.empty"
    case alreadyGripping = "say.already_gripping"

    /// The phrase has one `%d`, filled from the event's number.
    public var takesNumber: Bool {
        [.offlineSaved, .offlineDiscarded, .savedCount, .savedN].contains(self)
    }
}

/// One phrase as it is spoken: a key and its number, if it takes one.
public struct Phrase: Equatable, Sendable {
    public let key: SpeechKey
    public let number: Int?

    public init(_ key: SpeechKey, number: Int? = nil) {
        self.key = key
        self.number = number
    }
}

/// What one event plays.
public struct CueRow: Equatable, Sendable {
    public let key: CueKey
    public let haptic: Haptic?
    public let sound: Sound?
    /// Spoken in order, as one utterance.
    public let speech: [SpeechKey]
    /// Nil when nothing is spoken.
    public let level: SpeechLevel?

    init(
        _ key: CueKey, _ haptic: Haptic? = nil, sound: Sound? = nil, say speech: [SpeechKey] = [],
        _ level: SpeechLevel? = nil
    ) {
        self.key = key
        self.haptic = haptic
        self.sound = sound
        self.speech = speech
        self.level = speech.isEmpty ? nil : level
    }
}

/// Event to cue, one row per event (§5.3). Wording is in §8.2 and the app's `Speech` table.
public enum CueTable {
    public static let rows: [CueRow] = [
        CueRow(.holdLive, .go),

        CueRow(.refused(.noLink), .no, say: [.noLink], .p4),
        CueRow(.refused(.notStopped), .no, say: [.notStopped], .p4),
        CueRow(.refused(.emergencyStop), .no, say: [.stopped], .p4),
        CueRow(.refused(.notReady), .no, say: [.wait], .p4),
        CueRow(.refused(.busy), .no, say: [.wait], .p4),
        CueRow(.refused(.slowLink), .no, say: [.slowLink], .p4),
        CueRow(.refused(.notTracking), .no, say: [.notTracking], .p4),
        CueRow(.refused(.posture), .no, say: [.posture], .p4),
        CueRow(.refused(.letGoFirst), .no, say: [.letGoFirst], .p4),
        CueRow(.refused(.deadInput), .no),
        CueRow(.refused(.serverRefused), .no),

        CueRow(.limit(.workspace), .end),
        CueRow(.limit(.wrist), .end),
        CueRow(.limit(.fullyOpen), .end),
        CueRow(.limit(.blocked), .end, say: [.blocked], .p4),
        CueRow(.limit(.empty), .end, say: [.empty], .p4),
        CueRow(.limit(.alreadyGripping), .end, say: [.alreadyGripping], .p4),

        CueRow(.contact, .grip),

        // Felt only: it can come during a hold, many times a session, and the eyes stay on the arm.
        CueRow(.onTarget, .onTarget),

        CueRow(.letGo(.tooFast), .letGo, say: [.tooFast], .p4),
        CueRow(.letGo(.tracking), .letGo, say: [.lostTracking], .p4),
        CueRow(.letGo(.noAnswer), .letGo, say: [.noAnswer], .p4),
        CueRow(.letGo(.watchdog), .letGo, say: [.linkHiccup], .p4),
        CueRow(.letGo(.lateRejection), .letGo, say: [.refusedMove], .p4),

        CueRow(.emergencyStop(.button, takeDiscarded: false), .alarm, say: [.estop, .causeButton, .resetPrompt], .p1),
        CueRow(
            .emergencyStop(.button, takeDiscarded: true), .alarm,
            say: [.estop, .causeButton, .takeDiscarded, .resetPrompt], .p1),
        CueRow(.emergencyStop(.behind, takeDiscarded: false), .alarm, say: [.estop, .causeBehind, .resetPrompt], .p1),
        CueRow(
            .emergencyStop(.behind, takeDiscarded: true), .alarm,
            say: [.estop, .causeBehind, .takeDiscarded, .resetPrompt], .p1),
        CueRow(.emergencyStop(.other, takeDiscarded: false), .alarm, say: [.estop, .causeOther, .resetPrompt], .p1),
        CueRow(
            .emergencyStop(.other, takeDiscarded: true), .alarm,
            say: [.estop, .causeOther, .takeDiscarded, .resetPrompt], .p1),
        CueRow(.emergencyStop(.link, takeDiscarded: false), .alarm, say: [.estop, .causeLink, .resetPrompt], .p1),
        CueRow(
            .emergencyStop(.link, takeDiscarded: true), .alarm,
            say: [.estop, .causeLink, .takeDiscarded, .resetPrompt], .p1),
        CueRow(
            .emergencyStop(.onConnect, takeDiscarded: false), .alarm, say: [.estop, .causeOnConnect, .resetPrompt], .p1),
        CueRow(
            .emergencyStop(.onConnect, takeDiscarded: true), .alarm,
            say: [.estop, .causeOnConnect, .takeDiscarded, .resetPrompt], .p1),

        CueRow(.linkLost(holdEngaged: false), sound: .linkLost, say: [.linkLost], .p1),
        CueRow(.linkLost(holdEngaged: true), .letGo, sound: .linkLost, say: [.linkLost], .p1),

        CueRow(.reconnected, say: [.reconnected], .p2),
        CueRow(.serverRestarted, say: [.serverRestarted], .p2),
        CueRow(.takeContinues, say: [.takeContinues], .p2),
        CueRow(.offlineSaved, sound: .saved, say: [.offlineSaved], .p2),
        CueRow(.offlineDiscarded, sound: .discarded, say: [.offlineDiscarded], .p2),
        CueRow(.taskSuccess, sound: .saved, say: [.success], .p2),
        CueRow(.takeSaved, sound: .saved, say: [.savedN], .p2),
        CueRow(.successNotSaved, sound: .discarded, say: [.successNotSaved], .p2),
        CueRow(.takeDiscarded, sound: .discarded, say: [.takeDiscarded], .p2),
        CueRow(.ready, say: [.ready], .p2),
        CueRow(.recordingSession, say: [.recordingSession, .savedCount], .p2),
        CueRow(.notRecording, say: [.notRecording], .p2),
        CueRow(.notReset, say: [.notReset], .p2),
    ]

    private static let byKey: [CueKey: CueRow] = Dictionary(
        rows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

    public static func row(for key: CueKey) -> CueRow {
        // Every key has a row; CueTableTests holds the table to that.
        guard let row = byKey[key] else {
            assertionFailure("no cue row for \(key)")
            return CueRow(key)
        }
        return row
    }

    /// The utterance for an event, numbers filled in.
    public static func phrases(for event: FeedbackEvent) -> [Phrase] {
        row(for: event.key).speech.map { Phrase($0, number: $0.takesNumber ? event.number : nil) }
    }
}
