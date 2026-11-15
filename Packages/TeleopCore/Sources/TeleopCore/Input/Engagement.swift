/// The one thing engaged now (I-2: one thing at a time): a hold tied to an input that is down, or the reset countdown.
/// The input rules hold exactly one or none. Which inputs are down and what each is doing stays in
/// `InputArbiter.held`, a separate table.
///
/// Kept by `InputArbiter`: `.held(input, kind)` exactly when `held[input] == .engaged(kind)`, and that input is down.
public enum Engagement: Equatable, Sendable {
    /// A hold that lasts as long as its input is down.
    case held(HeldInput, HoldKind)
    /// The reset countdown of this top band touch.
    case countdown(touch: Int)

    /// The hold the session runs for it; nil for the countdown, which runs none.
    public var holdKind: HoldKind? {
        switch self {
        case .held(_, let kind): return kind
        case .countdown: return nil
        }
    }
}

/// Why every hold ends, as the part that sends `InputEvent.holdsEnded` knows it.
///
/// For a hold tied to an input and for the countdown every reason ends them alike: the hold stops, the countdown is
/// cancelled, and every input held now is dead until released. The default is `.unnamed`: a path that names no
/// reason is never taken for one whose cue has already played.
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
