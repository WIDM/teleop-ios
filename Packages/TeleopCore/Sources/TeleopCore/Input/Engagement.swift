import Foundation

/// The one thing engaged now (I-2: one thing at a time): who drives the arm, or the reset countdown. The input rules
/// hold exactly one or none. Which inputs are down and what each is doing stays in `InputArbiter.held`, a separate
/// table.
///
/// Who drives is part of the value: an input that is down (`.held`), or nobody (`.latched`). The case nobody drives
/// carries no input, so "engaged but not down" cannot be written for it.
///
/// Kept by `InputArbiter`:
/// - `.held(input, kind)` exactly when `held[input] == .engaged(kind)`, and that input is down.
/// - While `.latched`, no input reports `.engaged` or `.countingDown`; the session runs one arm hold.
/// - `.latched` exists only while `assist.lock` is set.
/// - No call that holds an accepted STOP touch-down leaves `.latched` behind.
public enum Engagement: Equatable, Sendable {
    /// A hold that lasts as long as its input is down.
    case held(HeldInput, HoldKind)
    /// The reset countdown of this top band touch.
    case countdown(touch: Int)
    /// The arm follows the phone with no input down, since `since` on the input rules' clock.
    case latched(since: TimeInterval)

    /// True for a move nobody holds.
    public var isLoose: Bool {
        switch self {
        case .latched: return true
        case .held, .countdown: return false
        }
    }

    /// The hold the session runs for it; nil for the countdown, which runs none. A move nobody holds is one
    /// translation hold in the session's sense.
    public var holdKind: HoldKind? {
        switch self {
        case .held(_, let kind): return kind
        case .latched: return .translation
        case .countdown: return nil
        }
    }
}

/// Why every hold ends, as the part that sends `InputEvent.holdsEnded` knows it.
///
/// For a hold tied to an input and for the countdown every reason ends them alike: the hold stops, the countdown is
/// cancelled, and every input held now is dead until released. For a move nobody holds, `.announced` and
/// `.startRefused` play nothing and every other reason plays its ending, so such a move never ends in silence. The
/// default is `.unnamed`, heard as "Stopped here.": a path that names no reason is never taken for one whose cue has
/// already played.
public enum Interruption: Equatable, Sendable {
    /// Nobody named the reason.
    case unnamed
    /// Whoever ended the session's hold has played its cue: the session's stop (ALARM), or link loss ("Link lost." and
    /// its sound).
    case announced
    /// The session or the link refused the start the rules accepted. Its refusal has played, as for any refused press,
    /// and nothing moved.
    case startRefused
    /// The app left the active state.
    case appLeft
    /// ARKit stopped the camera.
    case cameraStopped
    /// The session left the operating routes.
    case leftScreen
    /// The session latched a slow link, which plays nothing of its own.
    case slowLink
}
