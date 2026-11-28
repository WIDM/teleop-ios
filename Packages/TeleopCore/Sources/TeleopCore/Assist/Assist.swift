/// What the hands-free aids may do now: lock (a follow nobody holds), tap-to-go, the guide's additions, and what the
/// phone explains. The one configuration value every seam reads. Its `.off` is version 1.0.1 for every seam: every
/// member is nil, and every seam's nil path is its 1.0.1 path. A test holds `.off` to "every stored member is nil" by
/// reflection, so a new aid can only be added here as an optional member that is nil when off.
public struct Assist: Equatable, Sendable {
    /// Lock. Nil: releasing the upper key stops the arm, and a thumb that lands during its hold is judged as in 1.0.1.
    public var lock: LockRule?
    /// Tap-to-go. Nil: the guide's view from above takes no taps; a touch there is a thumb as in 1.0.1.
    public var goTo: GoToLimits?
    /// The guide's additions. Nil: the 1.0.1 guide, cues and on-target window.
    public var guide: GuideAids?
    /// What the phone says about its link beyond 1.0.1's words. Nil: a slow link that stops a held hold is shown on
    /// the screen only, as in 1.0.1.
    public var explain: ExplainAids?
    public var views: ViewAim?

    public init(
        lock: LockRule? = nil, goTo: GoToLimits? = nil, guide: GuideAids? = nil, explain: ExplainAids? = nil,
        views: ViewAim? = nil
    ) {
        self.lock = lock
        self.goTo = goTo
        self.guide = guide
        self.explain = explain
        self.views = views
    }

    /// Version 1.0.1.
    public static let off = Assist()

    /// The only way the app builds one. The master switch off gives `.off` whatever else is passed. With it on, each
    /// aid comes from the robot's share, lock only when the operator also chose a variant. A member whose numbers are
    /// unusable (not finite, or below their bound: above zero for most, not negative for the correction reach, the
    /// allowance, the start grace and the number of corrections) is left out here, so the rules trust what they get.
    /// Whether the travel height lies inside the box is judged per tap, where the box is known.
    ///
    /// There is no mode parameter: in buttons mode no key reaches the input rules and no guide is drawn, so nothing can
    /// latch or be tapped there.
    public static func resolve(masterOn: Bool, lockChoice: LockChoice, profile: AssistProfile) -> Assist {
        guard masterOn else { return .off }
        let lock = profile.lock.flatMap { limits -> LockRule? in
            guard limits.isUsable, let variant = lockChoice.variant else { return nil }
            return LockRule(variant: variant, timeLimitS: limits.timeLimitS)
        }
        let goTo = profile.goTo.flatMap { $0.isUsable ? $0 : nil }
        let views = goTo.flatMap { limits in
            profile.views.flatMap { $0.isUsable(travelHeightM: limits.travelHeightM) ? $0 : nil }
        }
        return Assist(lock: lock, goTo: goTo, guide: profile.guide, explain: profile.explain, views: views)
    }
}

/// The robot's share of the aids, a field of `RobotProfile`. A robot that forbids lock and gives no travel height has
/// `.none` and needs no code path of its own: it resolves as the master switch off does for lock and taps.
public struct AssistProfile: Equatable, Sendable {
    /// Nil: this robot never follows with no key held.
    public var lock: LockLimits?
    /// Nil: no travel height, so tapping the guide does nothing new.
    public var goTo: GoToLimits?
    /// Which guide additions suit this robot.
    public var guide: GuideAids?
    /// What the phone may say about its link with this robot. A robot that sets it also sets `guide`: with any aid on,
    /// the link takes a translation hold's start point when the start goes on the wire, and an aid that only speaks
    /// must not change that by itself.
    public var explain: ExplainAids?
    public var views: ViewAim?

    public init(
        lock: LockLimits? = nil, goTo: GoToLimits? = nil, guide: GuideAids? = nil, explain: ExplainAids? = nil,
        views: ViewAim? = nil
    ) {
        self.lock = lock
        self.goTo = goTo
        self.guide = guide
        self.explain = explain
        self.views = views
    }

    public static let none = AssistProfile()
}

/// Settings for the fixed aiming views, measured from the robot's tabletop.
public struct ViewAim: Equatable, Sendable {
    public var behindTopAboveTableM: Double
    public var maxRetargetedMoveS: Double?

    public init(behindTopAboveTableM: Double, maxRetargetedMoveS: Double? = nil) {
        self.behindTopAboveTableM = behindTopAboveTableM
        self.maxRetargetedMoveS = maxRetargetedMoveS
    }

    fileprivate func isUsable(travelHeightM: Double) -> Bool {
        behindTopAboveTableM.isFinite && behindTopAboveTableM >= travelHeightM && behindTopAboveTableM > 0
            && (maxRetargetedMoveS.map { $0.isFinite && $0 > 0 } ?? true)
    }
}

/// What the phone says about its link beyond 1.0.1's words. All false is the same as nil.
public struct ExplainAids: Equatable, Sendable {
    /// A hold the operator holds that a slow link stops lets go with "Slow link.", as a move nobody holds already ends
    /// with it; without this the slow link shows on the screen only.
    public var slowLinkLetGo: Bool

    public init(slowLinkLetGo: Bool) { self.slowLinkLetGo = slowLinkLetGo }
}

/// Lock's robot numbers. A robot cannot allow lock without saying how long a follow nobody holds may run.
public struct LockLimits: Equatable, Sendable {
    /// Longest a latched follow runs, counted from the latch, seconds.
    public var timeLimitS: Double

    public init(timeLimitS: Double) { self.timeLimitS = timeLimitS }

    /// A follow nobody holds must always have an end the rules can reach, so a limit that is zero, negative, infinite
    /// or not a number allows no lock at all.
    var isUsable: Bool { timeLimitS.isFinite && timeLimitS > 0 }
}

/// Settings' lock row, saved under "lockVariant" as its raw value.
public enum LockChoice: String, CaseIterable, Sendable {
    case off
    /// Variant 1: a press of the upper key starts the follow and its release does not stop it.
    case pressPress
    /// Variant 2: while the upper key is held, a thumb slid up 10 mm latches the follow.
    case holdThenSlide

    public var variant: LockVariant? {
        switch self {
        case .off: return nil
        case .pressPress: return .pressPress
        case .holdThenSlide: return .holdThenSlide
        }
    }
}

public enum LockVariant: Equatable, Sendable { case pressPress, holdThenSlide }

/// Lock as resolved: the operator's variant with the robot's limit.
public struct LockRule: Equatable, Sendable {
    public var variant: LockVariant
    public var timeLimitS: Double

    public init(variant: LockVariant, timeLimitS: Double) {
        self.variant = variant
        self.timeLimitS = timeLimitS
    }
}

/// Tap-to-go's robot numbers. Every number a going move uses is here or derives from here.
public struct GoToLimits: Equatable, Sendable {
    /// Height of the pinch point above the table for the level leg, metres.
    public var travelHeightM: Double
    /// Speed of the commanded pinch point along the path, metres per wall second.
    public var speedMps: Double
    /// A fresh measured pinch point this close to the target is "arrived"; one no lower than the travel height less
    /// this starts the level leg. Metres.
    public var arriveToleranceM: Double
    /// How many times a move that settled short may aim again by the remainder: on the vertical leg only the commanded
    /// height moves, on the level leg the leg's end.
    public var corrections: Int
    /// A remainder longer than this is not corrected: the move ends "stopped short". Metres.
    public var correctionReachM: Double
    /// How long fresh measured points must stay within 2 mm, with the command at its leg's end, to count as settled.
    public var settleS: Double
    /// The deadline is the path's length over `speedMps`, times this, plus `allowanceS`.
    public var timeFactor: Double
    public var allowanceS: Double
    /// No measured position younger than this ends the move ("No arm data."), seconds.
    public var armDataTimeoutS: Double
    /// After the start, or after the last pause of the hold if that ended later, a stall is judged only from positions
    /// measured this long after it, unless the arm has already been seen the feedback monitor's moved distance (2 mm)
    /// from where it started: a start the server takes late, or an arm that lags at first, is not a stall. Seconds; 0
    /// is no grace.
    public var startGraceS: Double
    /// How the move follows the arm's actual pace.
    public var pacing: GoToPacing

    public init(
        travelHeightM: Double, speedMps: Double, arriveToleranceM: Double, corrections: Int, correctionReachM: Double,
        settleS: Double, timeFactor: Double, allowanceS: Double, armDataTimeoutS: Double, startGraceS: Double = 0,
        pacing: GoToPacing
    ) {
        self.travelHeightM = travelHeightM
        self.speedMps = speedMps
        self.arriveToleranceM = arriveToleranceM
        self.corrections = corrections
        self.correctionReachM = correctionReachM
        self.settleS = settleS
        self.timeFactor = timeFactor
        self.allowanceS = allowanceS
        self.armDataTimeoutS = armDataTimeoutS
        self.startGraceS = startGraceS
        self.pacing = pacing
    }

    /// A measured position older than this says nothing about now, seconds.
    public var freshS: Double { Double(pacing.freshMs) / 1000 }

    /// A going move must always end by itself, so the numbers its path, its deadline and its watch on the arm data are
    /// built from have to make sense: a zero speed never arrives and a zero timeout ends every move at once. Zero
    /// corrections, a zero reach for one, a zero allowance past the path's own time and no start grace are accepted:
    /// they only make a move end sooner.
    var isUsable: Bool {
        let positive = [travelHeightM, speedMps, arriveToleranceM, settleS, armDataTimeoutS, timeFactor]
        let notNegative = [correctionReachM, allowanceS, startGraceS]
        return positive.allSatisfy { $0.isFinite && $0 > 0 } && notNegative.allSatisfy { $0.isFinite && $0 >= 0 }
            && corrections >= 0 && pacing.isUsable
    }
}

/// The numbers by which a going move follows how the arm actually answers (`GoMove`). They are tuned on one arm's
/// response: a laggy or springy arm needs other ones.
public struct GoToPacing: Equatable, Sendable {
    /// Each fresh reading moves the link command this share of the way to the offset it measured, between 0 and 1. The
    /// whole way overshoots where the jaws swing more than the link moves, since a reading shows a command's effect
    /// only one or two readings later.
    public var followShare: Double
    /// The command moves at the profile's speed times min(1, `paceGain` / swing), swing being the measured offset's
    /// change per unit of gripper-link travel.
    public var paceGain: Double
    /// The command never moves slower than this share of the speed, between 0 and 1.
    public var slowestShare: Double
    /// The share of the speed the command moves at until the first swing is measured, between 0 and 1.
    public var startShare: Double
    /// A fresh reading this many arrive tolerances from the leg ahead ends a following move stopped short.
    public var pathWatchTolerances: Double
    /// A measured position older than this says nothing about now, milliseconds.
    public var freshMs: Int
    /// Fresh measured points within this of one another count as standing still, and an arm this far from where it
    /// started has been seen to move, metres.
    public var stillM: Double
    /// The pace is set again only when the share it would move at changes by more than this share of the present one,
    /// between 0 and 1.
    public var paceChangeShare: Double

    public init(
        followShare: Double, paceGain: Double, slowestShare: Double, startShare: Double, pathWatchTolerances: Double,
        freshMs: Int, stillM: Double, paceChangeShare: Double
    ) {
        self.followShare = followShare
        self.paceGain = paceGain
        self.slowestShare = slowestShare
        self.startShare = startShare
        self.pathWatchTolerances = pathWatchTolerances
        self.freshMs = freshMs
        self.stillM = stillM
        self.paceChangeShare = paceChangeShare
    }

    /// The numbers a move divides by or times itself out with have to make sense: a zero start share never starts, a
    /// zero pace gain never moves, a negative freshness never accepts a reading.
    var isUsable: Bool {
        let shares = [followShare, paceGain, slowestShare, startShare]
        return shares.allSatisfy { $0.isFinite && $0 > 0 } && followShare <= 1 && slowestShare <= 1 && startShare <= 1
            && pathWatchTolerances.isFinite && pathWatchTolerances > 0 && freshMs > 0 && stillM.isFinite && stillM > 0
            && paceChangeShare.isFinite && paceChangeShare >= 0 && paceChangeShare <= 1
    }
}

/// Which of the guide's additions run. All false is the same as nil.
public struct GuideAids: Equatable, Sendable {
    /// The commanded point leaving the work area is felt, said with its side, and shown under the guide, every time.
    public var workAreaWords: Bool
    /// A stall against a downward command says "Can't go lower.", and the guide marks the lowest height reached.
    public var lowestCue: Bool
    /// A shadow under the pinch point in both views, wider and fainter the higher the jaws are.
    public var shadow: Bool
    /// "Forward" and "Up" arrows on the two views, and the same facts in their accessibility labels.
    public var directionLabels: Bool
    /// "On target" and its cue use the profile's `onTargetWindow` when it gives one.
    public var widerOnTarget: Bool

    public init(workAreaWords: Bool, lowestCue: Bool, shadow: Bool, directionLabels: Bool, widerOnTarget: Bool) {
        self.workAreaWords = workAreaWords
        self.lowestCue = lowestCue
        self.shadow = shadow
        self.directionLabels = directionLabels
        self.widerOnTarget = widerOnTarget
    }

    public static let all = GuideAids(
        workAreaWords: true, lowestCue: true, shadow: true, directionLabels: true, widerOnTarget: true)
}
