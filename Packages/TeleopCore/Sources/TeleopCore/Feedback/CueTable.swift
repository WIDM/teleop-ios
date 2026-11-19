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
    /// Queued while its announcement remains valid.
    case p2 = 2
    /// Spoken at once, during a hold too, or dropped if another phrase is playing.
    case p4 = 4

    public static func < (a: SpeechLevel, b: SpeechLevel) -> Bool { a.rawValue < b.rawValue }
}

/// A spoken phrase's key in the app's `Speech` string table (§8.2), which holds English and Traditional Chinese.
public enum SpeechKey: String, CaseIterable, Sendable {
    case ready = "say.ready"
    case voiceHeight = "say.voice.height"
    case voiceForeAft = "say.voice.fore_aft"
    case voiceLeftRight = "say.voice.left_right"
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
    /// What to do when the server refused or ended a hold because the arm touched something.
    case refusedContact = "say.refused.contact"
    /// What to do when the server refused or ended a hold at a joint's limit.
    case refusedJointLimit = "say.refused.joint_limit"
    /// What to do when the server refused or ended a hold because the arm cannot get there this way.
    case refusedReach = "say.refused.reach"
    case blocked = "say.blocked"
    case empty = "say.empty"
    case alreadyGripping = "say.already_gripping"
    case driveLocked = "say.drive.locked"
    case driveArrived = "say.drive.arrived"
    /// "Stopped here.": a move that ended. Never `stopped`, "Stopped.", which refuses a press while the robot is in
    /// emergency stop, so a refused input and an ended move never share a word.
    case driveStoppedHere = "say.drive.stopped_here"
    case driveTimeUp = "say.drive.time_up"
    case driveAppLeft = "say.drive.app_left"
    case driveCamera = "say.drive.camera"
    case driveLeftScreen = "say.drive.left_screen"
    case driveShort = "say.drive.short"
    /// Why a move nobody holds ended when the server was busy or not ready. Never `wait`, "Wait.", which after
    /// "Stopped here." would sound as if the move goes on after a wait.
    case driveServerBusy = "say.drive.server_busy"
    case noArmData = "say.reason.no_arm_data"
    case useUpperKey = "say.use_upper_key"
    case outside = "say.reason.outside"
    case lowest = "say.lowest"
    case rangeForward = "say.range.forward"
    case rangeBack = "say.range.back"
    case rangeLeft = "say.range.left"
    case rangeRight = "say.range.right"
    case rangeUp = "say.range.up"
    case rangeDown = "say.range.down"
    case tapStill = "say.tap_still"
    case tapLetGo = "say.tap_let_go"
    case tapViewAbove = "say.tap_view_above"
    /// Said after "Stopped here." when a touch on the tapped spot right after the tap ended the move.
    case tapOnce = "say.tap_once"

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
        CueRow(.voiceAxis(.height), nil, say: [.voiceHeight], .p4),
        CueRow(.voiceAxis(.foreAft), nil, say: [.voiceForeAft], .p4),
        CueRow(.voiceAxis(.leftRight), nil, say: [.voiceLeftRight], .p4),

        CueRow(.refused(.noLink), .no, say: [.noLink], .p4),
        // Queued, never dropped: it is the only word that a STOP has reached no robot, and it often comes while
        // "Link lost." or the alarm's own words still play.
        CueRow(.refused(.notStopped), .no, say: [.notStopped], .p2),
        CueRow(.refused(.emergencyStop), .no, say: [.stopped], .p4),
        CueRow(.refused(.notReady), .no, say: [.wait], .p4),
        CueRow(.refused(.busy), .no, say: [.wait], .p4),
        CueRow(.refused(.slowLink), .no, say: [.slowLink], .p4),
        CueRow(.refused(.notTracking), .no, say: [.notTracking], .p4),
        CueRow(.refused(.posture), .no, say: [.posture], .p4),
        CueRow(.refused(.letGoFirst), .no, say: [.letGoFirst], .p4),
        CueRow(.refused(.deadInput), .no),
        CueRow(.refused(.serverRefused), .no),
        CueRow(.refused(.useUpperKey), .no, say: [.useUpperKey], .p2),
        CueRow(.refused(.outsideWorkArea), .no, say: [.outside], .p4),
        CueRow(.refused(.noArmData), .no, say: [.noArmData], .p4),
        // Why a touch on the guide was not taken as a tap. Queued, never dropped: they often come right after
        // "Stopped here." or "Arrived.", and a dropped reason leaves only the NO.
        CueRow(.refused(.tapStill), .no, say: [.tapStill], .p2),
        CueRow(.refused(.tapLetGo), .no, say: [.tapLetGo], .p2),
        CueRow(.refused(.tapViewAbove), .no, say: [.tapViewAbove], .p2),

        CueRow(.limit(.workspace), .end),
        CueRow(.limit(.wrist), .end),
        CueRow(.limit(.fullyOpen), .end),
        CueRow(.limit(.blocked), .end, say: [.blocked], .p4),
        CueRow(.limit(.empty), .end, say: [.empty], .p4),
        CueRow(.limit(.alreadyGripping), .end, say: [.alreadyGripping], .p4),
        // A stall against a downward command, in place of "Blocked." and spoken as it is.
        CueRow(.limit(.lowest), .end, say: [.lowest], .p4),

        // The commanded position crossed out of the work area: END, and the side when the voice is free. The line
        // under the guide is the channel that stays.
        CueRow(.commandOutside(.forward), .end, say: [.rangeForward], .p4),
        CueRow(.commandOutside(.back), .end, say: [.rangeBack], .p4),
        CueRow(.commandOutside(.left), .end, say: [.rangeLeft], .p4),
        CueRow(.commandOutside(.right), .end, say: [.rangeRight], .p4),
        CueRow(.commandOutside(.up), .end, say: [.rangeUp], .p4),
        CueRow(.commandOutside(.down), .end, say: [.rangeDown], .p4),

        CueRow(.contact, .grip),

        // Felt only: it can come during a hold, many times a session, and the eyes stay on the arm.
        CueRow(.onTarget, .onTarget),

        CueRow(.letGo(.tooFast), .letGo, say: [.tooFast], .p4),
        CueRow(.letGo(.tracking), .letGo, say: [.lostTracking], .p4),
        CueRow(.letGo(.noAnswer), .letGo, say: [.noAnswer], .p4),
        CueRow(.letGo(.watchdog), .letGo, say: [.linkHiccup], .p4),
        CueRow(.letGo(.lateRejection), .letGo, say: [.refusedMove], .p4),
        CueRow(.letGo(.slowLink), .letGo, say: [.slowLink], .p4),

        // The server refused a hold's start (NO, as any refusal) or ended a running hold (LET GO, as any let-go), told
        // by what the operator can do. The general class says what `.refused(.serverRefused)` and
        // `.letGo(.lateRejection)` say.
        // The words of a classed refusal say what to do, so they wait for the voice instead of being dropped.
        CueRow(.serverRefusal(.contact, accepted: false), .no, say: [.refusedContact], .p2),
        CueRow(.serverRefusal(.jointLimit, accepted: false), .no, say: [.refusedJointLimit], .p2),
        CueRow(.serverRefusal(.reach, accepted: false), .no, say: [.refusedReach], .p2),
        CueRow(.serverRefusal(.other, accepted: false), .no),
        CueRow(.serverRefusal(.contact, accepted: true), .letGo, say: [.refusedContact], .p2),
        CueRow(.serverRefusal(.jointLimit, accepted: true), .letGo, say: [.refusedJointLimit], .p2),
        CueRow(.serverRefusal(.reach, accepted: true), .letGo, say: [.refusedReach], .p2),
        CueRow(.serverRefusal(.other, accepted: true), .letGo, say: [.refusedMove], .p4),

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

        // A move nobody holds announces its start and ending. A waiting latch is cancelled when that move ends.
        // Latching has its own pattern, so it is never taken for GO.
        CueRow(.drive(.latched), .latch, say: [.driveLocked], .p2),
        CueRow(.drive(.arrived), .end, say: [.driveArrived], .p2),
        CueRow(.drive(.stoppedByYou), .end, say: [.driveStoppedHere], .p2),
        CueRow(.drive(.stoppedByYouTapOnce), .end, say: [.driveStoppedHere, .tapOnce], .p2),
        ending(.unnamed),
        ending(.posture),
        ending(.tracking),
        ending(.timeLimit),
        ending(.appLeft),
        ending(.cameraStopped),
        ending(.leftScreen),
        ending(.slowLink),
        ending(.stoppedShort),
        ending(.noArmData),
        ending(.tooFast),
        ending(.noAnswer),
        ending(.linkHiccup),
        ending(.serverRefused),
        ending(.serverBusy),
        serverEnding(.contact),
        serverEnding(.jointLimit),
        serverEnding(.reach),
        serverEnding(.other),
    ]

    /// An ending the operator did not cause says "Stopped here." and then why, or "Stopped here." alone when nobody
    /// named the reason.
    private static func ending(_ end: DriveEnd) -> CueRow {
        CueRow(.drive(.ended(end)), .letGo, say: [.driveStoppedHere] + reason(end), .p2)
    }

    /// What follows "Stopped here.": the existing reason phrase where one exists. A total switch, so a new ending does
    /// not compile without its words.
    private static func reason(_ end: DriveEnd) -> [SpeechKey] {
        switch end {
        case .unnamed: return []
        case .posture: return [.posture]
        case .tracking: return [.lostTracking]
        case .timeLimit: return [.driveTimeUp]
        case .appLeft: return [.driveAppLeft]
        case .cameraStopped: return [.driveCamera]
        case .leftScreen: return [.driveLeftScreen]
        case .slowLink: return [.slowLink]
        case .stoppedShort: return [.driveShort]
        case .noArmData: return [.noArmData]
        case .tooFast: return [.tooFast]
        case .noAnswer: return [.noAnswer]
        case .linkHiccup: return [.linkHiccup]
        case .serverRefused: return [.refusedMove]
        case .serverBusy: return [.driveServerBusy]
        }
    }

    /// A move nobody holds that the server refused or ended says "Stopped here." and then what to do about it.
    private static func serverEnding(_ refusalClass: ServerRefusalClass) -> CueRow {
        CueRow(
            .drive(.endedByServer(refusalClass)), .letGo, say: [.driveStoppedHere] + serverReason(refusalClass), .p2)
    }

    /// What to do about a server's refusal of this class; the general class keeps the general refusal words. A total
    /// switch, so a new class does not compile without its words.
    private static func serverReason(_ refusalClass: ServerRefusalClass) -> [SpeechKey] {
        switch refusalClass {
        case .contact: return [.refusedContact]
        case .jointLimit: return [.refusedJointLimit]
        case .reach: return [.refusedReach]
        case .other: return [.refusedMove]
        }
    }

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
