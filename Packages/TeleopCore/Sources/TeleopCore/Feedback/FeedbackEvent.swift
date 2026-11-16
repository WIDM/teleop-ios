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

    /// Every key. Built from `Kind`, whose cases the compiler lists, so a key cannot be left out by hand: a new case
    /// here does not compile until `kind` names its kind, and a new kind does not compile until `keys(of:)` lists
    /// its keys.
    public static var allCases: [CueKey] { Kind.allCases.flatMap(keys(of:)) }

    /// A key without its payload.
    enum Kind: CaseIterable {
        case holdLive, refused, limit, contact, onTarget, letGo, emergencyStop, linkLost, reconnected, serverRestarted
        case takeContinues, offlineSaved, offlineDiscarded, taskSuccess, takeSaved, successNotSaved, takeDiscarded
        case ready, recordingSession, notRecording, notReset
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
        }
    }
}
