/// The pad's hold buttons (INTERACTION §3.2). Version 1 has no wrist buttons.
public enum ButtonID: String, CaseIterable, Sendable {
    case forward, back, left, right, up, down, open, close

    /// Which way a direction button moves the arm; nil for the gripper buttons.
    public var direction: OperatorDirection? {
        switch self {
        case .forward: return .forward
        case .back: return .back
        case .left: return .left
        case .right: return .right
        case .up: return .up
        case .down: return .down
        case .open, .close: return nil
        }
    }
}

/// What the pad asks the app to do. The arbiter sends nothing itself.
public enum ButtonCommand: Equatable, Sendable {
    /// `pose_start` for a translation hold.
    case startTranslation(OperatorDirection)
    /// The ramp's target on every 30 Hz tick while the hold runs: metres, in the frame
    /// `TeleopLink.poseUpdate(positionMeters:)` takes. It is the whole way asked for since the press and grows for
    /// as long as the button is held, so it is not what one `pose_update` carries: it takes the place of the
    /// phone's offset and goes through the link's 8 cm lead cap and resync (§3.3) like that offset does.
    case updateTranslation(SIMD3<Double>)
    /// `pose_stop`.
    case stopTranslation
    /// `gripper_jog_start` toward `open` or `closed`, then keepalives until the stop.
    case startGripper(GripperState)
    /// `gripper_jog_stop`.
    case stopGripper
    /// The speed changed: `mode{step}` goes out once, and probes carry it from now on (§3.3, §3.5).
    case speedChanged(ButtonSpeed)
    case cue(ButtonCue)
}

/// The cues the pad's own rules ask for (§5.3). Acceptance (GO) and the limits are judged elsewhere.
public enum ButtonCue: Equatable, Sendable {
    /// NO, with no speech: a press while another button is down. That press stays dead until it is released.
    case deadInput
    /// END + "Already gripping." (`say.already_gripping`): Close while gripping. Nothing is sent (A-2g).
    case alreadyGripping
    /// NO + "Let go first." (`say.let_go_first`): the Fine / Coarse switch while a button is down.
    case speedRefused
}

/// The pad's rules (INTERACTION §3.3): hold a button to move, let go to stop, one button at a time.
/// Pure: time and the gripping fact come in, commands come out for the app to carry out.
public struct ButtonArbiter: Equatable, Sendable {
    public private(set) var speed: ButtonSpeed
    /// The button whose hold runs now.
    public private(set) var engaged: ButtonID?
    /// Every button with a finger on it, whether it runs a hold, was refused or is dead. A finger that slipped off
    /// its button no longer counts.
    public private(set) var down: Set<ButtonID> = []
    /// The running translation hold's target.
    public private(set) var ramp: ButtonRamp?

    public init(speed: ButtonSpeed = .coarse) {
        self.speed = speed
    }

    /// A finger came down on `button`. `gripping`: the last gripper hold ended with contact, and since then no
    /// open has run, no reset and no new server run (A-2g). The app knows that, as it does for the phone schemes.
    public mutating func press(_ button: ButtonID, atMs nowMs: Int, gripping: Bool) -> [ButtonCommand] {
        guard !down.contains(button) else { return [] }
        let anotherIsDown = !down.isEmpty
        down.insert(button)
        if anotherIsDown { return [.cue(.deadInput)] }
        if button == .close, gripping { return [.cue(.alreadyGripping)] }
        engaged = button
        if let direction = button.direction {
            ramp = ButtonRamp(direction: direction, speed: speed, startMs: nowMs)
            return [.startTranslation(direction)]
        }
        return [.startGripper(button == .open ? .open : .closed)]
    }

    /// The finger lifted off `button`, or left it by more than `ButtonPadLayout.slipPt`. Either ends its hold;
    /// a dead or refused button goes quietly.
    public mutating func release(_ button: ButtonID) -> [ButtonCommand] {
        guard down.remove(button) != nil, engaged == button else { return [] }
        engaged = nil
        if ramp != nil {
            ramp = nil
            return [.stopTranslation]
        }
        return [.stopGripper]
    }

    /// Every 30 Hz tick: the running translation hold's target.
    public func tick(atMs nowMs: Int) -> [ButtonCommand] {
        guard engaged != nil, let ramp else { return [] }
        return [.updateTranslation(ramp.offset(atMs: nowMs))]
    }

    /// The arm stopped following the ramp (§5.6): the target stops moving until the button is released.
    public mutating func rampBlocked(atMs nowMs: Int) {
        ramp?.freeze(atMs: nowMs)
    }

    /// The app or the server ended the running hold while its button is still down (a refusal, a lost link, an
    /// emergency stop). Nothing more is sent for it, and the button stays dead until it is released.
    public mutating func holdEnded() {
        engaged = nil
        ramp = nil
    }

    /// The Fine / Coarse switch was tapped. Refused while any button is down.
    public mutating func selectSpeed(_ newSpeed: ButtonSpeed) -> [ButtonCommand] {
        guard down.isEmpty else { return [.cue(.speedRefused)] }
        guard newSpeed != speed else { return [] }
        speed = newSpeed
        return [.speedChanged(newSpeed)]
    }
}
