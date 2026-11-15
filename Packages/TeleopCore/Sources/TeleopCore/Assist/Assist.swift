/// What the hands-free aids may do now: lock (a follow nobody holds), tap-to-go, and the guide's additions. The one
/// configuration value every seam reads. Its `.off` is version 1.0.1 for every seam: every member is nil, and every
/// seam's nil path is its 1.0.1 path. A test holds `.off` to "every stored member is nil" by reflection, so a new aid
/// can only be added here as an optional member that is nil when off.
public struct Assist: Equatable, Sendable {
    /// Lock. Nil: releasing the upper key stops the arm, and a thumb that lands during its hold is judged as in 1.0.1.
    public var lock: LockRule?
    /// Tap-to-go. Nil: the guide's view from above takes no taps; a touch there is a thumb as in 1.0.1.
    public var goTo: GoToLimits?
    /// The guide's additions. Nil: the 1.0.1 guide, cues and on-target window.
    public var guide: GuideAids?

    public init(lock: LockRule? = nil, goTo: GoToLimits? = nil, guide: GuideAids? = nil) {
        self.lock = lock
        self.goTo = goTo
        self.guide = guide
    }

    /// Version 1.0.1.
    public static let off = Assist()

    /// The only way the app builds one. The master switch off gives `.off` whatever else is passed. With it on, each
    /// aid comes from the robot's share, lock only when the operator also chose a variant. A member whose numbers are
    /// unusable (not finite, not positive) is left out here, so the rules trust what they get. Whether the travel height
    /// lies inside the box is judged per tap, where the box is known.
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
        return Assist(lock: lock, goTo: goTo, guide: profile.guide)
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

    public init(lock: LockLimits? = nil, goTo: GoToLimits? = nil, guide: GuideAids? = nil) {
        self.lock = lock
        self.goTo = goTo
        self.guide = guide
    }

    public static let none = AssistProfile()
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
    /// A fresh measured pinch point this close to the target is "arrived"; this close to the travel height starts the
    /// level leg. Metres.
    public var arriveToleranceM: Double
    /// How many times a move that settled short may aim again by the remainder.
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

    public init(
        travelHeightM: Double, speedMps: Double, arriveToleranceM: Double, corrections: Int, correctionReachM: Double,
        settleS: Double, timeFactor: Double, allowanceS: Double, armDataTimeoutS: Double
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
    }

    /// A going move must always end by itself, so the numbers its path, its deadline and its watch on the arm data are
    /// built from have to make sense: a zero speed never arrives and a zero timeout ends every move at once. Zero
    /// corrections, a zero reach for one and a zero allowance past the path's own time are accepted: they only make a
    /// move end sooner.
    var isUsable: Bool {
        let positive = [travelHeightM, speedMps, arriveToleranceM, settleS, armDataTimeoutS, timeFactor]
        let notNegative = [correctionReachM, allowanceS]
        return positive.allSatisfy { $0.isFinite && $0 > 0 } && notNegative.allSatisfy { $0.isFinite && $0 >= 0 }
            && corrections >= 0
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
