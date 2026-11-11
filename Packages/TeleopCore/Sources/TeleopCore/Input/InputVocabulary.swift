import simd

/// The two phone schemes (§2.4, §2.5). The owner picks one by hand.
public enum InputScheme: Equatable, Sendable {
    /// Scheme A, "Screen turns": vol+ moves the arm, vol− closes the jaws, a thumb held on the glass turns the
    /// wrist as the phone turns, and a slide up the glass opens the jaws.
    case screenTurns
    /// Scheme B, "Key turns": vol+ moves the arm, vol− turns the wrist as the phone turns, holding the half under
    /// the thumb closes the jaws and holding the other half opens them.
    case keyTurns
}

/// The volume keys: `upper` is vol+ (the capture interaction's secondary), `lower` is vol− (primary).
public enum InputKey: Hashable, Sendable {
    case upper, lower

    var other: InputKey { self == .upper ? .lower : .upper }
}

/// One raw UIKit touch event on the operating screen.
public struct TouchSample: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case began, moved, ended, cancelled }

    /// Stable for one touch from `began` to `ended` or `cancelled`.
    public var id: Int
    public var phase: Phase
    /// Points in the operating screen's coordinates, origin top left.
    public var x: Double
    public var y: Double
    /// `UITouch.majorRadius`, points.
    public var majorRadius: Double

    public init(id: Int, phase: Phase, x: Double, y: Double, majorRadius: Double) {
        self.id = id
        self.phase = phase
        self.x = x
        self.y = y
        self.majorRadius = majorRadius
    }
}

public enum InputEvent: Equatable, Sendable {
    /// `began`. A repeated `began` while the key is down is ignored.
    case keyDown(InputKey)
    /// `ended` or `cancelled`.
    case keyUp(InputKey)
    case touch(TouchSample)
    /// The phone's attitude in portrait device axes (`PhoneAttitude.portrait`), about 60 times a second.
    case attitude(simd_quatd)
    /// Lets the timers run out on time: the palm window, the scheme B dwell, the reset countdown. Send ticks at
    /// least at 30 Hz, or at `nextDeadline`.
    case tick
    /// Every hold ends and every input held now is dead until released (I-11, H4): the app left the active state,
    /// a sheet opened, the link was lost, ARKit was interrupted, the thermal state became critical, or the server
    /// ended the engaged hold itself.
    case endAllHolds
    /// A scheme or Hand change. Ends every hold first, as `endAllHolds`.
    case modeChanged(InputScheme, Hand)
    /// The server reset the scene (`ok scene_reset`, an `episode` change or a new `welcome.session`). On an
    /// unknown server the tilt window counts commanded tilt from here.
    case sceneReset
    /// The engaged wrist hold's `orient_start` went on the wire now. If it waited behind a finishing hold, the
    /// rotation made meanwhile is dropped (I-8.1).
    case wristStartSent
}

/// Why a press does nothing, as the operator will hear it (E2).
public enum InputRefusal: Equatable, Sendable {
    /// `say.reason.no_link`
    case noLink
    /// `say.stopped`: the robot is in emergency stop.
    case stopped
    /// `say.wait`: the server is not ready (success display, resetting).
    case wait
    /// `say.reason.slow_link`
    case slowLink
    /// `say.reason.not_tracking`: ARKit is limited or interrupted.
    case notTracking
    /// `say.reason.posture`: the phone is held so that translation cannot be mapped.
    case posture
    /// `say.reason.settings_open`
    case settingsOpen
    /// `say.reason.too_hot`
    case tooHot
    /// `say.reset_first`: a take in progress needs a reset (§6.6).
    case resetFirst
    /// `say.let_go_first`: the top band or the gear area while something is engaged. Decided here.
    case letGoFirst
    /// `say.reason.not_stopped`: STOP with neither connection up. Decided here.
    case notStopped
}

/// What the rest of the app tells the arbiter on every call.
public struct InputFacts: Equatable, Sendable {
    /// Why no start may be sent now, whatever it would start; nil when starts may go out.
    public var refusal: InputRefusal?
    /// Why a start that needs the phone's pose (translation, wrist) may not go out, typically `.notTracking`.
    public var trackingRefusal: InputRefusal?
    /// Why translation alone may not start, typically `.posture`.
    public var translationRefusal: InputRefusal?
    /// Why the reset countdown may not run or fire (§6.4 step 1: `.wait` during the success display). The
    /// countdown works in the E-stop state, so `refusal` does not apply to it.
    public var resetRefusal: InputRefusal?
    /// The last gripper hold ended with contact, and since then no open has run, no reset and no new server run
    /// (A-2g). Close is then refused and opening in scheme B needs the long dwell.
    public var gripping: Bool
    /// Measured wrist angles for the windows (I-8.3).
    public var wrist: WristReadings
    /// The control or the observer connection is up, so STOP reaches the server.
    public var connectionUp: Bool

    public init(
        refusal: InputRefusal? = nil, trackingRefusal: InputRefusal? = nil, translationRefusal: InputRefusal? = nil,
        resetRefusal: InputRefusal? = nil, gripping: Bool = false, wrist: WristReadings = .unknown,
        connectionUp: Bool = true
    ) {
        self.refusal = refusal
        self.trackingRefusal = trackingRefusal
        self.translationRefusal = translationRefusal
        self.resetRefusal = resetRefusal
        self.gripping = gripping
        self.wrist = wrist
        self.connectionUp = connectionUp
    }
}

public enum HoldKind: Equatable, Sendable {
    case translation
    /// `.open` opens the jaws, `.closed` closes them.
    case gripper(GripperState)
    case wrist
}

/// A cue the feedback layer plays for an input decision.
public enum InputCue: Equatable, Sendable {
    /// NO with no speech: an input that began while something else was engaged (I-2.1, I-2.4), or an unclear
    /// gesture (A-4b, A-5, B-3m).
    case dead
    /// NO and the reason.
    case refused(InputRefusal)
    /// END: a wrist clamp or window was reached (I-8.3).
    case limit
    /// END and "Already gripping." (A-2g, B-3c).
    case alreadyGripping
}

public enum InputCommand: Equatable, Sendable {
    case startTranslation
    case stopTranslation
    case startGripper(GripperState)
    case stopGripper
    case startWrist
    /// The engaged wrist hold's target from now on. Stream the newest one at 30 Hz.
    case wristUpdate(WristTarget)
    case stopWrist
    case emergencyStop
    /// The top band was held past its palm window: say "Keep holding to reset."
    case resetCountdownStarted
    /// The top band was let go of before 2.0 s, or a hold ended the countdown. Silent.
    case resetCountdownCancelled
    /// The top band was held 2.0 s and the reset checks passed: say "Resetting." and run the reset procedure.
    case fireReset
    case openSettings
    case cue(InputCue)
}

/// An input that can be held down.
public enum HeldInput: Hashable, Sendable {
    case key(InputKey)
    case touch(Int)
}

/// What a held input is doing now.
public enum InputPhase: Equatable, Sendable {
    /// Not yet decided: a scheme A touch before it commits, a scheme B touch in its dwell, a top band or gear touch.
    case waiting
    case engaged(HoldKind)
    /// The top band's reset countdown, which counts as engaged.
    case countingDown
    /// Ignored until released: dead, refused, or already used.
    case dead
}
