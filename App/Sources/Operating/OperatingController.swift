import Foundation
import simd
import TeleopCore

/// The only place where the phone's inputs become commands: the volume keys, touches on the operating screen and
/// the phone's attitude go through the input rules (`InputArbiter`, schemes A and B), and the pad's buttons through
/// `ButtonArbiter`. Each command they return becomes a session action or a link call on the model, and each cue
/// becomes `raise(_:)`. In buttons mode the input rules still judge the bands (STOP, the reset hold, the gear).
///
/// Main queue only. Time is the uptime clock, which `UITouch.timestamp` and `ARFrame.timestamp` use too.
final class OperatingController {
    /// Every route the operating screen draws, where the operator drives the robot. Leaving them (Settings, Connect,
    /// the tutorial) ends every hold (I-11); moving between them keeps it.
    static let operatingRoutes: Set<Route> = RootView.operatingRoutes

    private unowned let model: AppModel
    let now: () -> TimeInterval
    private(set) var arbiter: InputArbiter
    private(set) var buttons = ButtonArbiter()
    private(set) var mode: ControlMode
    private var hand: Hand
    /// When the reset countdown began, while it runs.
    private var countdownStartedAt: TimeInterval?
    /// The model's `stopEpoch` when the countdown's touch began.
    private var countdownStopEpoch: Int?
    /// The model's `stopEpoch` when each top band touch began: the countdown dates from the touch that started it,
    /// even when it starts in the same step as a stop.
    private var topBandTouchEpochs: [Int: Int] = [:]
    /// The engaged wrist hold's newest target, before the lead bound.
    private(set) var wristTarget = WristTarget.identity
    /// Buttons mode: touches that began in the control surface belong to the pad, not to the input rules.
    private var padTouches: Set<Int> = []
    private var wasOnOperatingScreen: Bool
    private var wasStopped: Bool
    private var wasConnected: Bool
    private var wasBlocked: Bool
    private var cameraStopped = false
    /// The reason given with the newest `holdsEnded` fed to the input rules.
    private(set) var lastInterruption: Interruption?
    private var queue: [Step] = []
    private var running = false
    private var timer: Timer?

    private enum Step {
        case events([InputEvent], TimeInterval)
        case press(ButtonID)
        case release(ButtonID)
        case speed(ButtonSpeed)
        /// The pad's running hold ends with its stop, and its button stays dead until lifted (I-11).
        case endButtonHold
    }

    init(
        model: AppModel, mode: ControlMode, hand: Hand, constants: InputConstants, assist: Assist,
        now: @escaping () -> TimeInterval
    ) {
        self.model = model
        self.mode = mode
        self.hand = hand
        self.now = now
        arbiter = InputArbiter(
            scheme: Self.scheme(mode) ?? .screenTurns, hand: hand,
            layout: SurfaceLayout(width: 402, height: 874, safeTop: 62, safeBottom: 34, constants: constants),
            constants: constants, assist: assist
        )
        wasOnOperatingScreen = Self.operatingRoutes.contains(model.session.route)
        wasStopped = model.session.state.emergencyStop
        wasConnected = model.session.state.connected
        wasBlocked = model.session.state.commandsBlocked
    }

    deinit { timer?.invalidate() }

    /// Starts the 30 Hz tick that lets the input rules' timers run out and the button ramps advance.
    func startTicking() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Raw inputs

    func key(_ key: InputKey, down: Bool) {
        guard mode != .buttons else { return }
        feed([down ? .keyDown(key) : .keyUp(key)], at: now())
    }

    func touch(_ sample: TouchSample, at time: TimeInterval) {
        if mode == .buttons {
            if sample.phase == .began, arbiter.layout.zone(x: sample.x, y: sample.y) == .controlSurface {
                padTouches.insert(sample.id)
            }
            if padTouches.contains(sample.id) {
                if sample.phase == .ended || sample.phase == .cancelled { padTouches.remove(sample.id) }
                return
            }
        }
        if sample.phase == .began, arbiter.layout.zone(x: sample.x, y: sample.y) == .topBand {
            topBandTouchEpochs[sample.id] = model.stopEpoch
        }
        feed([.touch(sample)], at: time)
        if sample.phase == .ended || sample.phase == .cancelled { topBandTouchEpochs[sample.id] = nil }
    }

    func attitude(_ attitude: simd_quatd, at time: TimeInterval) {
        guard mode != .buttons else { return }
        feed([.attitude(attitude)], at: time)
    }

    func buttonDown(_ button: ButtonID) { enqueue(.press(button)) }
    func buttonUp(_ button: ButtonID) { enqueue(.release(button)) }
    func selectSpeed(_ speed: ButtonSpeed) { enqueue(.speed(speed)) }

    func tick() {
        feed([.tick], at: now())
    }

    // MARK: What the rest of the app reports

    func layoutChanged(_ layout: SurfaceLayout) {
        arbiter.layout = layout
    }

    func modeChanged(_ mode: ControlMode, hand: Hand) {
        self.mode = mode
        self.hand = hand
        releaseAllButtons()
        padTouches = []
        feed([.modeChanged(Self.scheme(mode) ?? arbiter.scheme, hand)], at: now())
    }

    /// The aids' configuration changed in Settings. Ends every hold, as a mode change does.
    func assistChanged(_ assist: Assist) {
        feed([.assistChanged(assist)], at: now())
    }

    /// The app left or returned to the active state (I-11): every hold ends on leaving, and every input held across
    /// it stays dead until released.
    func activeChanged(_ active: Bool) {
        if !active { enqueue(.endButtonHold) }
        feed([active ? .becameActive : .holdsEnded(.appLeft)], at: now())
    }

    /// ARKit stopped or restarted the camera: holds end, and inputs held across it stay dead.
    func cameraInterrupted(_ interrupted: Bool) {
        guard interrupted != cameraStopped else { return }
        cameraStopped = interrupted
        if interrupted { enqueue(.endButtonHold) }
        feed([interrupted ? .holdsEnded(.cameraStopped) : .becameActive], at: now())
    }

    var isCameraStopped: Bool { cameraStopped }

    /// The server reset the scene, started a new episode or a new run.
    func sceneReset() {
        feed([.sceneReset], at: now())
    }

    /// The wrist hold's `orient_start` went on the wire.
    func wristStartSent() {
        feed([.wristStartSent], at: now())
    }

    /// The session changed. A hold the server, the link, STOP or a screen ended is ended in the rules too, with the
    /// reason as far as it is known, and leaving the operating screen ends every hold. `told`: what the model knows of
    /// this change that the session does not show, such as a start it carried that the session or the link refused.
    func sessionChanged(told: Interruption? = nil) {
        let onScreen = Self.operatingRoutes.contains(model.session.route)
        let left = wasOnOperatingScreen && !onScreen
        wasOnOperatingScreen = onScreen
        // A stop the server reports (another client's STOP, a safety stop) ends a reset counting down as the STOP
        // band does: in the stop state that reset would release the stop it never saw. Every held input stays dead.
        let stopped = model.session.state.emergencyStop
        let newlyStopped = stopped && !wasStopped
        wasStopped = stopped
        let connected = model.session.state.connected
        let lostLink = wasConnected && !connected
        wasConnected = connected
        let blocked = model.session.state.commandsBlocked
        let newlyBlocked = blocked && !wasBlocked
        wasBlocked = blocked
        if let held = buttons.engaged {
            if !Self.holds(held, model.session.state) {
                buttons.holdEnded()
            } else if left {
                enqueue(.endButtonHold)
            }
        }
        let holdGone = arbiter.engagedHold.map { !Self.holds($0, model.session.state) } ?? false
        guard left || newlyStopped || holdGone else { return }
        // The stop's ALARM and the lost link's sound and words have played. Otherwise the reason is never assumed to
        // have been told: one nobody names is heard as unnamed.
        let reason: Interruption =
            newlyStopped || lostLink ? .announced : told ?? (newlyBlocked ? .slowLink : left ? .leftScreen : .unnamed)
        feed([.holdsEnded(reason)], at: now())
    }

    // MARK: Reading the state

    /// Something is engaged: a hold of either set of rules, or the reset countdown.
    var isEngaged: Bool {
        arbiter.engagedHold != nil || countdownStartedAt != nil || buttons.engaged != nil
    }

    var engagedHold: HoldKind? {
        if let kind = arbiter.engagedHold { return kind }
        switch buttons.engaged {
        case .open?: return .gripper(.open)
        case .close?: return .gripper(.closed)
        case nil: return nil
        default: return .translation
        }
    }

    /// 0…1 while the top band is held toward a reset.
    var resetCountdown: Double? {
        countdownStartedAt.map { min(max((now() - $0) / arbiter.constants.resetHoldS, 0), 1) }
    }

    /// The running button hold's target, metres in the link's frame, for the link to stream.
    func buttonTarget() -> SIMD3<Double>? {
        guard case .updateTranslation(let offset)? = buttons.tick(atMs: milliseconds(now())).first else { return nil }
        return offset
    }

    // MARK: Carrying out

    private func feed(_ events: [InputEvent], at time: TimeInterval) {
        for case .holdsEnded(let reason) in events { lastInterruption = reason }
        enqueue(.events(events, time))
    }

    /// Steps run one at a time: a command can make the model report back (a start that went out, a session
    /// change), and that report waits for the step that caused it to finish.
    private func enqueue(_ step: Step) {
        queue.append(step)
        guard !running else { return }
        running = true
        defer { running = false }
        while !queue.isEmpty {
            let next = queue.removeFirst()
            switch next {
            case .events(let events, let time):
                var commands = arbiter.handle(events, at: time, facts: model.inputFacts())
                // A countdown that ran out between ticks fires in the same step as a STOP pressed just after: the
                // reset would go out ahead of the STOP and could clear it, so the STOP wins.
                if commands.contains(.emergencyStop) { commands.removeAll { $0 == .fireReset } }
                for command in commands { carry(command) }
            case .press(let button):
                press(button)
            case .release(let button):
                for command in buttons.release(button) { carry(command) }
            case .speed(let speed):
                for command in buttons.selectSpeed(speed) { carry(command) }
            case .endButtonHold:
                endButtonHold()
            }
            model.inputsChanged()
        }
    }

    private func press(_ button: ButtonID) {
        let facts = model.inputFacts()
        let commands = buttons.press(button, atMs: milliseconds(now()), gripping: facts.gripping)
        let starts = commands.contains {
            if case .startTranslation = $0 { true } else if case .startGripper = $0 { true } else { false }
        }
        if starts, countdownStartedAt != nil {
            // The reset countdown counts as engaged (I-3): the press is dead until it is released.
            buttons.holdEnded()
            model.raise(.refused(.deadInput))
            return
        }
        if starts, let refusal = facts.refusal {
            // The button stays dead until it is released, as a refused key does.
            buttons.holdEnded()
            model.raise(.refused(Self.refusal(refusal)))
            return
        }
        for command in commands { carry(command) }
    }

    private func carry(_ command: InputCommand) {
        switch command {
        case .startTranslation: model.send(.holdArmStart)
        case .stopTranslation: model.send(.holdArmEnd)
        case .startGripper(let target): model.send(.gripperStart(target))
        case .stopGripper: model.send(.gripperEnd)
        case .startWrist:
            wristTarget = .identity
            model.send(.wristStart)
        case .wristUpdate(let target):
            wristTarget = target
            model.link.setWristTarget(target)
        case .stopWrist:
            wristTarget = .identity
            model.send(.wristEnd)
        case .emergencyStop: model.send(.stop)
        case .resetCountdownStarted:
            countdownStartedAt = now()
            countdownStopEpoch = arbiter.countdownTouchID.flatMap { topBandTouchEpochs[$0] } ?? model.stopEpoch
        case .resetCountdownCancelled:
            countdownStartedAt = nil
            countdownStopEpoch = nil
        case .fireReset:
            countdownStartedAt = nil
            let epoch = countdownStopEpoch
            countdownStopEpoch = nil
            model.runReset(stopEpochAtStart: epoch)
        case .openSettings:
            // The input rules do not see the pad's holds: a gear tap during one is dead (§2.2).
            if buttons.engaged != nil {
                model.raise(.refused(.letGoFirst))
            } else {
                model.send(.openSettings)
            }
        case .cue(let cue): cueRaised(cue)
        }
    }

    private func carry(_ command: ButtonCommand) {
        switch command {
        case .startTranslation: model.startButtonTranslation()
        case .updateTranslation: break
        case .stopTranslation: model.send(.holdArmEnd)
        case .startGripper(let target): model.send(.gripperStart(target))
        case .stopGripper: model.send(.gripperEnd)
        case .speedChanged: break
        case .cue(.deadInput): model.raise(.refused(.deadInput))
        case .cue(.alreadyGripping): model.raise(.limit(.alreadyGripping))
        case .cue(.speedRefused): model.raise(.refused(.letGoFirst))
        }
    }

    private func cueRaised(_ cue: InputCue) {
        switch cue {
        case .dead: model.raise(.refused(.deadInput))
        // STOP with no connection up: the session's own stop path says "No link. Not stopped." for every STOP.
        case .refused(.notStopped): break
        case .refused(let refusal): model.raise(.refused(Self.refusal(refusal)))
        case .limit: model.raise(.limit(.wrist))
        case .alreadyGripping: model.raise(.limit(.alreadyGripping))
        case .drive(let drive): model.raise(.drive(drive))
        }
    }

    /// Stops the pad's running hold as a lift would. Its button stays down and dead until it is lifted.
    private func endButtonHold() {
        guard let held = buttons.engaged else { return }
        buttons.holdEnded()
        carry(held.direction == nil ? ButtonCommand.stopGripper : .stopTranslation)
    }

    /// A mode or hand change, refused while a hold runs: the pad goes away, so nothing on it stays down.
    private func releaseAllButtons() {
        buttons.holdEnded()
        for button in buttons.down { _ = buttons.release(button) }
    }

    private func milliseconds(_ time: TimeInterval) -> Int { Int((time * 1000).rounded()) }

    // MARK: Mapping

    private static func scheme(_ mode: ControlMode) -> InputScheme? {
        switch mode {
        case .screenTurns: return .screenTurns
        case .keyTurns: return .keyTurns
        case .buttons: return nil
        }
    }

    /// Whether the session still runs the hold the rules think is engaged.
    private static func holds(_ kind: HoldKind, _ state: FakeTeleopState) -> Bool {
        switch kind {
        case .translation: return state.armMoving
        case .gripper(let target): return state.gripperMoving == target
        case .wrist: return state.wristMoving
        }
    }

    private static func holds(_ button: ButtonID, _ state: FakeTeleopState) -> Bool {
        switch button {
        case .open: return state.gripperMoving == .open
        case .close: return state.gripperMoving == .closed
        default: return state.armMoving
        }
    }

    /// The reason the operator hears. Settings, heat and a take that needs a reset have no phrase in version 1's cue
    /// table yet, so they play NO alone.
    static func refusal(_ refusal: InputRefusal) -> Refusal {
        switch refusal {
        case .noLink: return .noLink
        case .stopped: return .emergencyStop
        case .wait: return .notReady
        case .slowLink: return .slowLink
        case .notTracking: return .notTracking
        case .posture: return .posture
        case .letGoFirst: return .letGoFirst
        case .notStopped: return .notStopped
        case .settingsOpen, .tooHot, .resetFirst: return .deadInput
        case .outsideWorkArea: return .outsideWorkArea
        case .noArmData: return .noArmData
        }
    }
}
