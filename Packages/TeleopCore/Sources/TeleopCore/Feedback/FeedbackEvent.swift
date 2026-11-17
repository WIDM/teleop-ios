/// Why a press did nothing (interaction specification E2, I-5).
public enum Refusal: String, CaseIterable, Sendable {
    case noLink
    /// A STOP that reached no server: pressed before a connection was welcomed, or lost with the link before the server
    /// confirmed it.
    case notStopped
    case emergencyStop
    /// The server refused the start because the success is shown or the scene is resetting.
    case notReady
    /// The server refused the start `busy`, after the wait for the previous control's final ack.
    case busy
    case slowLink
    case notTracking
    /// The phone is held sideways or face down for a translation.
    case posture
    /// The press needs every other input let go first, as a scene reset does.
    case letGoFirst
    /// An input that began while another was engaged. The operator's card already says why, so nothing is spoken.
    case deadInput
    /// The server refused the start for a reason the operator cannot act on (a validation code).
    case serverRefused
    /// A tap asked for a point outside the work box.
    case outsideWorkArea
    /// A tap found no measured arm position fresh enough to start from.
    case noArmData
}

/// As far as it goes (E4).
public enum Limit: String, CaseIterable, Sendable {
    /// The server clamped the arm to its workspace box.
    case workspace
    /// The server clamped the wrist.
    case wrist
    case fullyOpen
    /// The arm stopped short of where it is asked to go.
    case blocked
    /// The jaws closed on nothing.
    case empty
    /// Close pressed again while the jaws hold something.
    case alreadyGripping
    /// The arm stopped against a downward command. Played in place of `.blocked` with the guide's aids on.
    case lowest
}

/// Why the app or the server ended a hold the operator still holds (E3).
public enum LetGoReason: String, CaseIterable, Sendable {
    case tooFast
    case tracking
    /// A hold the app restarts on its own got no final ack for its stop in time.
    case noAnswer
    /// The server's watchdog ended the hold: no update reached it for 750 ms.
    case watchdog
    /// The server refused the hold after GO had played.
    case lateRejection
}

/// What the operator is told caused an emergency stop (§5.3, E-stop causes).
public enum EmergencyCause: String, CaseIterable, Sendable {
    /// STOP on the phone, or a STOP remembered from an outage.
    case button
    /// The arm fell too far behind the commanded point.
    case behind
    /// Another client, a server fault, or an unexplained stop.
    case other
    /// Found after a reconnect, when a hold was engaged at the loss.
    case link
    /// Found after a reconnect with nothing engaged, or on a fresh launch.
    case onConnect
}

/// Why a move nobody holds ended, as the operator hears it after "Stopped here.". One case per reason the operator can
/// act on or should know; the reason phrases are the existing ones where one exists.
public enum DriveEnd: Hashable, Sendable, CaseIterable {
    /// No one named it: "Stopped here." alone.
    case unnamed
    case posture
    case tracking
    case timeLimit
    case appLeft
    case cameraStopped
    case leftScreen
    case slowLink
    /// A going move settled short of its target after its corrections, or a following move took a fresh reading off
    /// the leg ahead or one that did not report the pinch point.
    case stoppedShort
    /// A going move heard no measured position for the profile's timeout.
    case noArmData
    case tooFast
    case noAnswer
    case linkHiccup
    case serverRefused
    case serverBusy

    /// How the link's own let-go reasons are told for a move nobody holds. A total switch: a new `LetGoReason` does not
    /// compile until it names its ending.
    public init(byLink reason: LetGoReason) {
        switch reason {
        case .tooFast: self = .tooFast
        case .tracking: self = .tracking
        case .noAnswer: self = .noAnswer
        case .watchdog: self = .linkHiccup
        case .lateRejection: self = .serverRefused
        }
    }

    /// How a refusal of a move nobody holds is told; nil when another cue tells it: `estop_active`, which the monitor
    /// turns into `.emergencyStop`, is told by the alarm, so whoever converts a refusal to nil records the ending as
    /// told. A total switch. Refusals no server sends for a running hold read as unnamed.
    public init?(refused refusal: Refusal) {
        switch refusal {
        case .busy, .notReady: self = .serverBusy
        case .serverRefused: self = .serverRefused
        case .emergencyStop: return nil
        case .noLink, .notStopped, .slowLink, .notTracking, .posture, .letGoFirst, .deadInput, .outsideWorkArea,
            .noArmData:
            self = .unnamed
        }
    }
}

/// What a move nobody holds tells the operator: that it latched, arrived, or ended and why. Every one is queued speech
/// with a haptic, so it is never dropped.
public enum DriveCue: Hashable, Sendable {
    /// A follow nobody holds began. Its own haptic, so it is never taken for GO.
    case latched
    /// A going move's measured pinch point reached the target.
    case arrived
    /// The operator's own key press or touch ended it.
    case stoppedByYou
    /// Anything else ended it.
    case ended(DriveEnd)

    public static var allCases: [DriveCue] {
        [.latched, .arrived, .stoppedByYou] + DriveEnd.allCases.map(DriveCue.ended)
    }
}

/// Everything the operator can perceive in version 1. Each one is felt, heard or both, as `CueTable` says.
public enum FeedbackEvent: Equatable, Sendable {
    /// E1: the start went out and no refusal came within the acceptance time. `hold` names the operator's hold.
    case holdLive(hold: Int)
    /// E2
    case refused(Refusal)
    /// E4
    case limit(Limit)
    /// E5: the jaws met something while closing.
    case contact
    /// The guide's "On target" turned true with the jaws open (`OnTargetCue`).
    case onTarget
    /// E3
    case letGo(LetGoReason)
    /// E7. `takeDiscarded`: a take was being captured, so the stop threw it away.
    case emergencyStop(EmergencyCause, takeDiscarded: Bool)
    /// E8. `holdEngaged`: a hold was running when the link went.
    case linkLost(holdEngaged: Bool)
    /// E9
    case reconnected
    case serverRestarted
    case takeContinues
    case offlineSaved(Int)
    case offlineDiscarded(Int)
    /// E10b: a success on a server without a recorder.
    case taskSuccess
    /// E10: `count` is the recorder's new saved total.
    case takeSaved(count: Int)
    /// E10c
    case successNotSaved
    /// E11
    case takeDiscarded
    /// E12
    case ready
    /// E22
    case recordingSession(saved: Int)
    /// E30: moving while the recorder is off. Once per take.
    case notRecording
    /// E20: the server could not take the reset.
    case notReset
    /// A move nobody holds latched, arrived or ended.
    case drive(DriveCue)
    /// The position the phone commands left the work area on this side, in the operator's words. A case of its own,
    /// not a `Limit`, because a `Limit` carries no side.
    case commandOutside(OperatorDirection)

    /// The table row this event plays.
    public var key: CueKey {
        switch self {
        case .holdLive: return .holdLive
        case .refused(let refusal): return .refused(refusal)
        case .limit(let limit): return .limit(limit)
        case .contact: return .contact
        case .onTarget: return .onTarget
        case .letGo(let reason): return .letGo(reason)
        case .emergencyStop(let cause, let discarded): return .emergencyStop(cause, takeDiscarded: discarded)
        case .linkLost(let engaged): return .linkLost(holdEngaged: engaged)
        case .reconnected: return .reconnected
        case .serverRestarted: return .serverRestarted
        case .takeContinues: return .takeContinues
        case .offlineSaved: return .offlineSaved
        case .offlineDiscarded: return .offlineDiscarded
        case .taskSuccess: return .taskSuccess
        case .takeSaved: return .takeSaved
        case .successNotSaved: return .successNotSaved
        case .takeDiscarded: return .takeDiscarded
        case .ready: return .ready
        case .recordingSession: return .recordingSession
        case .notRecording: return .notRecording
        case .notReset: return .notReset
        case .drive(let cue): return .drive(cue)
        case .commandOutside(let side): return .commandOutside(side)
        }
    }

    /// The number a spoken phrase carries, if any.
    public var number: Int? {
        switch self {
        case .offlineSaved(let count), .offlineDiscarded(let count): return count
        case .takeSaved(let count), .recordingSession(let count): return count
        default: return nil
        }
    }
}

/// An event without its numbers: one row of `CueTable` each.
public enum CueKey: Hashable, Sendable, CaseIterable {
    case holdLive
    case refused(Refusal)
    case limit(Limit)
    case contact
    case onTarget
    case letGo(LetGoReason)
    case emergencyStop(EmergencyCause, takeDiscarded: Bool)
    case linkLost(holdEngaged: Bool)
    case reconnected
    case serverRestarted
    case takeContinues
    case offlineSaved
    case offlineDiscarded
    case taskSuccess
    case takeSaved
    case successNotSaved
    case takeDiscarded
    case ready
    case recordingSession
    case notRecording
    case notReset
    case drive(DriveCue)
    case commandOutside(OperatorDirection)

    /// Every key. Built from `Kind`, whose cases the compiler lists, so a key cannot be left out by hand: a new case
    /// here does not compile until `kind` names its kind, and a new kind does not compile until `keys(of:)` lists
    /// its keys.
    public static var allCases: [CueKey] { Kind.allCases.flatMap(keys(of:)) }

    /// A key without its payload.
    enum Kind: CaseIterable {
        case holdLive, refused, limit, contact, onTarget, letGo, emergencyStop, linkLost, reconnected, serverRestarted
        case takeContinues, offlineSaved, offlineDiscarded, taskSuccess, takeSaved, successNotSaved, takeDiscarded
        case ready, recordingSession, notRecording, notReset, drive, commandOutside
    }

    var kind: Kind {
        switch self {
        case .holdLive: return .holdLive
        case .refused: return .refused
        case .limit: return .limit
        case .contact: return .contact
        case .onTarget: return .onTarget
        case .letGo: return .letGo
        case .emergencyStop: return .emergencyStop
        case .linkLost: return .linkLost
        case .reconnected: return .reconnected
        case .serverRestarted: return .serverRestarted
        case .takeContinues: return .takeContinues
        case .offlineSaved: return .offlineSaved
        case .offlineDiscarded: return .offlineDiscarded
        case .taskSuccess: return .taskSuccess
        case .takeSaved: return .takeSaved
        case .successNotSaved: return .successNotSaved
        case .takeDiscarded: return .takeDiscarded
        case .ready: return .ready
        case .recordingSession: return .recordingSession
        case .notRecording: return .notRecording
        case .notReset: return .notReset
        case .drive: return .drive
        case .commandOutside: return .commandOutside
        }
    }

    static func keys(of kind: Kind) -> [CueKey] {
        switch kind {
        case .holdLive: return [.holdLive]
        case .refused: return Refusal.allCases.map(CueKey.refused)
        case .limit: return Limit.allCases.map(CueKey.limit)
        case .contact: return [.contact]
        case .onTarget: return [.onTarget]
        case .letGo: return LetGoReason.allCases.map(CueKey.letGo)
        case .emergencyStop:
            return EmergencyCause.allCases.flatMap { cause in
                [false, true].map { CueKey.emergencyStop(cause, takeDiscarded: $0) }
            }
        case .linkLost: return [.linkLost(holdEngaged: false), .linkLost(holdEngaged: true)]
        case .reconnected: return [.reconnected]
        case .serverRestarted: return [.serverRestarted]
        case .takeContinues: return [.takeContinues]
        case .offlineSaved: return [.offlineSaved]
        case .offlineDiscarded: return [.offlineDiscarded]
        case .taskSuccess: return [.taskSuccess]
        case .takeSaved: return [.takeSaved]
        case .successNotSaved: return [.successNotSaved]
        case .takeDiscarded: return [.takeDiscarded]
        case .ready: return [.ready]
        case .recordingSession: return [.recordingSession]
        case .notRecording: return [.notRecording]
        case .notReset: return [.notReset]
        case .drive: return DriveCue.allCases.map(CueKey.drive)
        case .commandOutside: return OperatorDirection.allCases.map(CueKey.commandOutside)
        }
    }
}
