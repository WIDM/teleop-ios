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
    private(set) var precisionPanelOpen = false
    private var precisionKeys: Set<InputKey> = []
    private var savedButtonSpeed: ButtonSpeed?
    /// When the fine panel's entry stopped a move nobody holds. The panel opens once that stop is heard, as a second
    /// press would; anything else started meanwhile drops the ask, and a stop not heard in `panelAskWaitS` gives up.
    private var panelAskedAt: TimeInterval?
    /// The fine panel's page: the move buttons, or the wrist buttons in the cross's place.
    private(set) var panelPage: PanelPage = .move
    /// The wrist button whose hold runs now.
    private(set) var wristRamp: WristButtonRamp?
    /// Wrist buttons with a finger on them, running a hold or dead until lifted.
    private(set) var wristDown: Set<WristButton> = []
    /// The running wrist button's hold has played its limit cue.
    private var wristLimitCued = false
    static let panelAskWaitS = 1.5
    var panelAsked: Bool { panelAskedAt != nil }
    private var active = true
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
    /// The app's belief that the camera is stopped: set by ARKit's report that it stopped the camera, cleared by its
    /// report that it gave it back or by a frame that shows the camera runs again (`cameraFrame(stampedAt:)`).
    private var cameraStopped = false
    /// The newest report that the camera stopped, on the uptime clock.
    private var markSetAt: TimeInterval?
    /// The tracker's newest run of the camera session, with the time read just before it.
    private var lastRunAt: TimeInterval?
    /// Which run of the phone's tracking the attitude samples come from, as the input rules are told: one more at each
    /// run and at each camera stop.
    private(set) var attitudeFrame = 0
    /// The newest run or camera stop. No attitude sample stamped at or before it reaches the rules: it was captured in
    /// the run before, or before the camera stopped, even if it is handed over after.
    private var attitudeFrameSince: TimeInterval = -.infinity
    private var queue: [Step] = []
    private var running = false
    private var timer: Timer?

    private enum Step {
        case events([InputEvent], TimeInterval)
        case press(ButtonID)
        case release(ButtonID)
        case speed(ButtonSpeed)
        case precision(Bool)
        case page(PanelPage)
        case wristPress(WristButton)
        case wristRelease(WristButton)
        case axis(TranslationAxis?)
        /// The pad's running hold ends with its stop, and its button stays dead until lifted (I-11).
        case endButtonHold
        /// The attitude frame moves, and the input rules see it in a call of their own, after every step queued before
        /// it: a camera stop's end of every hold included.
        case newAttitudeFrame
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
        if down { dropAskedPanel() }
        if down, precisionPanelOpen || precisionKeys.contains(key) || !buttons.down.isEmpty {
            precisionKeys.insert(key)
            return
        }
        if !down { precisionKeys.remove(key) }
        feed([down ? .keyDown(key) : .keyUp(key)], at: now())
    }

    func touch(_ sample: TouchSample, at time: TimeInterval) {
        // Any new touch, the gear and the bands included, is the operator doing something else.
        if sample.phase == .began { dropAskedPanel() }
        if mode == .buttons || precisionPanelOpen || !buttons.down.isEmpty {
            if sample.phase == .began, arbiter.layout.zone(x: sample.x, y: sample.y) == .controlSurface {
                padTouches.insert(sample.id)
            }
        }
        if padTouches.contains(sample.id) {
            if sample.phase == .ended || sample.phase == .cancelled { padTouches.remove(sample.id) }
            return
        }
        if sample.phase == .began, arbiter.layout.zone(x: sample.x, y: sample.y) == .topBand {
            topBandTouchEpochs[sample.id] = model.stopEpoch
        }
        feed([.touch(sample)], at: time)
        if sample.phase == .ended || sample.phase == .cancelled { topBandTouchEpochs[sample.id] = nil }
    }

    func attitude(_ attitude: simd_quatd, at time: TimeInterval) {
        guard mode != .buttons, !precisionPanelOpen, time > attitudeFrameSince else { return }
        feed([.attitude(attitude)], at: time)
    }

    func buttonDown(_ button: ButtonID) { enqueue(.press(button)) }
    func buttonUp(_ button: ButtonID) { enqueue(.release(button)) }
    func selectSpeed(_ speed: ButtonSpeed) { enqueue(.speed(speed)) }
    func setPrecisionPanelOpen(_ open: Bool) { enqueue(.precision(open)) }
    func setPanelPage(_ page: PanelPage) { enqueue(.page(page)) }
    func wristButtonDown(_ button: WristButton) { enqueue(.wristPress(button)) }
    func wristButtonUp(_ button: WristButton) { enqueue(.wristRelease(button)) }
    func selectTranslationAxis(_ axis: TranslationAxis?) { enqueue(.axis(axis)) }

    func tick() {
        model.measurementTick()
        tickWristButton()
        feed([.tick], at: now())
    }

    // MARK: What the rest of the app reports

    func layoutChanged(_ layout: SurfaceLayout) {
        arbiter.layout = layout
    }

    func modeChanged(_ mode: ControlMode, hand: Hand) {
        model.disableVoiceAxis(reason: "mode_changed")
        setPrecisionPanelOpen(false)
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
        self.active = active
        if !active {
            model.disableVoiceAxis(reason: "background")
            setPrecisionPanelOpen(false)
            enqueue(.endButtonHold)
        }
        feed([active ? .becameActive : .holdsEnded(.appLeft)], at: now())
    }

    /// ARKit stopped the camera (true) or reported that it gave it back (false). A stop ends every hold, inputs held
    /// across it stay dead, and once the holds have ended the attitude samples start a new frame. Each report of a stop
    /// dates the mark anew, also while it is set, so a frame stamped before the newest one never clears it.
    func cameraInterrupted(_ interrupted: Bool) {
        guard interrupted else {
            guard cameraStopped else { return }
            cameraStopped = false
            model.sessionRecord.note("camera mark cleared by the end report")
            feed([.becameActive], at: now())
            return
        }
        model.disableVoiceAxis(reason: "camera_interrupted")
        markSetAt = now()
        if !cameraStopped {
            cameraStopped = true
            model.sessionRecord.note("camera mark set")
            enqueue(.endButtonHold)
            feed([.holdsEnded(.cameraStopped)], at: now())
        }
        startAttitudeFrame(since: now())
    }

    /// The tracker ran the camera session; `time` was read just before the run. The run has a world frame of its own,
    /// so the attitude samples start a new frame.
    func trackerRan(at time: TimeInterval) {
        lastRunAt = time
        startAttitudeFrame(since: time)
    }

    /// A camera frame arrived, stamped `stamp`, whether or not tracking was normal for it. When the tracker ran the
    /// session after the newest report of a stop, the first frame stamped after that run shows the camera runs, and
    /// the mark clears: ARKit may send no report that the camera is back when the session was paused during the stop,
    /// as leaving the operating screen does. The input rules are told nothing: every input since the run began after
    /// it, and every input from before it ended when the operating screen or the app was left.
    func cameraFrame(stampedAt stamp: TimeInterval) {
        guard cameraStopped, let run = lastRunAt, let stop = markSetAt, run > stop, stamp > run else { return }
        cameraStopped = false
        model.sessionRecord.noteLater { "camera mark cleared by a frame after the app's run stamp=\(stamp)" }
        model.inputsChanged()
    }

    var isCameraStopped: Bool { cameraStopped }

    /// The server reset the scene, started a new episode or a new run.
    func sceneReset() {
        model.disableVoiceAxis(reason: "scene_reset")
        setPrecisionPanelOpen(false)
        feed([.sceneReset], at: now())
    }

    /// The wrist hold's `orient_start` went on the wire.
    func wristStartSent() {
        if wristRamp != nil {
            wristRamp?.started(at: now())
            return
        }
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
        if left || newlyStopped || lostLink || newlyBlocked {
            model.disableVoiceAxis(reason: "session_interrupted")
            setPrecisionPanelOpen(false)
        }
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
        arbiter.engagedHold != nil || countdownStartedAt != nil || buttons.engaged != nil || wristRamp != nil
    }

    var engagedHold: HoldKind? {
        if let kind = arbiter.engagedHold { return kind }
        if wristRamp != nil { return .wrist }
        switch buttons.engaged {
        case .open?: return .gripper(.open)
        case .close?: return .gripper(.closed)
        case nil: return nil
        default: return .translation
        }
    }

    /// The move nobody holds, for the screen's words; nil otherwise.
    var loose: Engagement? { arbiter.engagement.flatMap { $0.isLoose ? $0 : nil } }

    /// The move to a point's offset since it started, metres in the link's frame, for the link to stream; nil when
    /// none runs. The rules judge it on their own clock.
    func goOffset() -> SIMD3<Double>? { arbiter.goOffset(at: now()) }

    /// Where the move to a point is headed, robot base frame, pinch point, for the guide; nil when none runs.
    var goTarget: SIMD3<Double>? {
        if case .going(let target, _)? = arbiter.engagement { return target }
        return nil
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
        enqueue(.events(events, time))
    }

    /// A run or a camera stop at `time`: from now on no sample stamped at or before it reaches the rules, and the
    /// count they are told moves in a step of its own, after the steps already queued.
    private func startAttitudeFrame(since time: TimeInterval) {
        attitudeFrameSince = time
        enqueue(.newAttitudeFrame)
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
                handle(events, at: time)
            case .newAttitudeFrame:
                attitudeFrame += 1
                handle([], at: now())
            case .press(let button):
                press(button)
            case .release(let button):
                for command in buttons.release(button) { carry(command) }
                restoreButtonSpeed()
            case .speed(let speed):
                guard !precisionPanelOpen else { continue }
                for command in buttons.selectSpeed(speed) { carry(command) }
            case .precision(let open):
                changePrecisionPanel(open)
            case .page(let page):
                changePage(page)
            case .wristPress(let button):
                pressWrist(button)
            case .wristRelease(let button):
                releaseWrist(button)
            case .axis(let axis):
                let commands = arbiter.selectTranslationAxis(axis, at: now(), facts: model.inputFacts())
                var starts = ArraySlice<ArmSource>()
                for command in commands { carry(command, starts: &starts) }
            case .endButtonHold:
                endButtonHold()
            }
            settleAskedPanel()
            model.inputsChanged()
        }
    }

    private func handle(_ events: [InputEvent], at time: TimeInterval) {
        var commands = arbiter.handle(events, at: time, facts: model.inputFacts())
        // A countdown that ran out between ticks fires in the same step as a STOP pressed just after: the reset would
        // go out ahead of the STOP and could clear it, so the STOP wins.
        if commands.contains(.emergencyStop) { commands.removeAll { $0 == .fireReset } }
        // What each start of this call was, in order, as the rules recorded it. Steps run one at a time, so no other
        // call to the rules can change the record while this one is carried.
        var starts = arbiter.startsThisCall[...]
        for command in commands { carry(command, starts: &starts) }
    }

    private func changePrecisionPanel(_ open: Bool) {
        if !open { dropAskedPanel() }
        guard open != precisionPanelOpen, panelAskedAt == nil else { return }
        if open {
            model.disableVoiceAxis(reason: "fine_panel")
            if loose != nil, panelMayOpen(beforeTheArmStops: true), model.inputFacts().refusal == nil {
                handle([.controlPressed], at: now())
                panelAskedAt = now()
                model.sessionRecord.note("precision panel asked: the move nobody holds stopped")
                settleAskedPanel()
                return
            }
            guard panelMayOpen(beforeTheArmStops: false) else {
                model.raise(.refused(.letGoFirst))
                return
            }
            if let refusal = model.inputFacts().refusal {
                model.raise(.refused(Self.refusal(refusal)))
                return
            }
            openPanel()
        } else {
            endButtonHold()
            precisionPanelOpen = false
            panelPage = .move
            restoreButtonSpeed()
            model.sessionRecord.note("precision panel closed")
        }
    }

    /// Whether the panel may open now. `beforeTheArmStops`: the press is about to stop a move nobody holds, so that
    /// move, the arm's motion and the link's word on its stop are not judged yet.
    private func panelMayOpen(beforeTheArmStops: Bool) -> Bool {
        let state = model.session.state
        guard mode != .buttons, active, Self.operatingRoutes.contains(model.session.route),
            countdownStartedAt == nil, buttons.engaged == nil, !arbiter.isHoldingAnInput, buttons.down.isEmpty,
            precisionKeys.isEmpty, padTouches.isEmpty, topBandTouchEpochs.isEmpty,
            state.gripperMoving == nil, !state.wristMoving
        else { return false }
        if beforeTheArmStops { return true }
        return arbiter.engagedHold == nil && !state.armMoving
            && (!state.liveLink || model.link.armHeardAfterLastStop)
    }

    private func openPanel() {
        savedButtonSpeed = buttons.speed
        _ = buttons.selectSpeed(.fine)
        precisionPanelOpen = true
        model.sessionRecord.note("precision panel opened")
    }

    /// The asked panel opens once the stop is heard. Anything the operator or the session starts meanwhile, or a
    /// refusal, drops the ask in silence: that event is heard on its own. A stop not heard in time plays NO.
    private func settleAskedPanel() {
        guard let askedAt = panelAskedAt else { return }
        if arbiter.engagement != nil || !panelMayOpen(beforeTheArmStops: true) || model.inputFacts().refusal != nil {
            return dropAskedPanel()
        }
        if now() - askedAt >= Self.panelAskWaitS {
            panelAskedAt = nil
            model.sessionRecord.note("precision panel ask timed out")
            model.raise(.refused(.deadInput))
        } else if panelMayOpen(beforeTheArmStops: false) {
            panelAskedAt = nil
            openPanel()
        }
    }

    private func dropAskedPanel() {
        guard panelAskedAt != nil else { return }
        panelAskedAt = nil
        model.sessionRecord.note("precision panel ask dropped")
    }

    private func restoreButtonSpeed() {
        guard !precisionPanelOpen, buttons.down.isEmpty, let speed = savedButtonSpeed else { return }
        _ = buttons.selectSpeed(speed)
        savedButtonSpeed = nil
    }

    private func press(_ button: ButtonID) {
        let facts = model.inputFacts()
        let commands = buttons.press(button, atMs: milliseconds(now()), gripping: facts.gripping)
        let starts = commands.contains {
            if case .startTranslation = $0 { true } else if case .startGripper = $0 { true } else { false }
        }
        if starts,
            !active || !Self.operatingRoutes.contains(model.session.route)
                || (mode != .buttons && !precisionPanelOpen) || arbiter.isHoldingAnInput
                || arbiter.engagedHold != nil || countdownStartedAt != nil || !wristDown.isEmpty
                || model.session.state.armMoving || model.session.state.gripperMoving != nil
                || model.session.state.wristMoving
                || (precisionPanelOpen && model.session.state.liveLink && !model.link.armHeardAfterLastStop)
        {
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

    private func carry(_ command: InputCommand, starts: inout ArraySlice<ArmSource>) {
        switch command {
        // The rules recorded what each start was. The engagement after the call cannot say: a STOP later in the same
        // call has already ended a move to a point, and its start would go out as a phone hold.
        case .startTranslation:
            if starts.popFirst() == .going { model.startArmHold(.going) } else { model.send(.holdArmStart) }
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
        // The latch is told only while the session runs the arm hold: a start refused in the same step has played its
        // refusal, and nothing moved.
        case .cue(.drive(.latched)): _ = model.armHoldBecameLoose()
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
        endWristButtonHold()
        guard let held = buttons.engaged else { return }
        buttons.holdEnded()
        carry(held.direction == nil ? ButtonCommand.stopGripper : .stopTranslation)
    }

    // MARK: The wrist page

    private func changePage(_ page: PanelPage) {
        guard page != panelPage else { return }
        guard precisionPanelOpen, buttons.down.isEmpty, wristDown.isEmpty, buttons.engaged == nil, wristRamp == nil
        else {
            model.raise(.refused(.letGoFirst))
            return
        }
        panelPage = page
        model.sessionRecord.note("precision panel page \(page.rawValue)")
    }

    private func pressWrist(_ button: WristButton) {
        guard wristDown.insert(button).inserted else { return }
        model.sessionRecord.note("wrist button \(button.rawValue) down")
        let state = model.session.state
        guard precisionPanelOpen, panelPage == .wrist, active, Self.operatingRoutes.contains(model.session.route),
            wristDown.count == 1, buttons.down.isEmpty, !isEngaged, !arbiter.isHoldingAnInput,
            !state.armMoving, state.gripperMoving == nil, !state.wristMoving
        else {
            model.raise(.refused(.deadInput))
            return
        }
        let facts = model.inputFacts()
        if let refusal = facts.refusal {
            model.raise(.refused(Self.refusal(refusal)))
            return
        }
        let range = RotationMapper.limits(
            for: button.axis, readings: facts.wrist, commandedTiltSinceResetDeg: arbiter.commandedTiltSinceReset,
            constants: arbiter.constants)
        wristRamp = WristButtonRamp(button: button, range: range)
        wristLimitCued = false
        wristTarget = WristTarget(axis: button.axis, degrees: 0)
        if !model.startPadWrist() {
            wristRamp = nil
            wristTarget = .identity
        }
    }

    private func releaseWrist(_ button: WristButton) {
        guard wristDown.remove(button) != nil else { return }
        model.sessionRecord.note("wrist button \(button.rawValue) up")
        guard wristRamp?.button == button else { return }
        endWristButtonHold()
    }

    /// Ends the running wrist button's hold, as a lift does. A finger still on the button keeps it dead until lifted.
    private func endWristButtonHold() {
        guard let ramp = wristRamp else { return }
        wristRamp = nil
        wristTarget = .identity
        if ramp.button.axis == .tilt { arbiter.addPanelTilt(ramp.target(at: now()).degrees) }
        if model.session.state.wristMoving { model.send(.wristEnd) }
    }

    /// The running wrist button's angle for this tick, and the limit cue once when it reaches the end of its range.
    private func tickWristButton() {
        guard let ramp = wristRamp else { return }
        guard model.session.state.wristMoving else {
            // The server, the link or a STOP ended the hold: nothing more goes out for it.
            endWristButtonHold()
            return
        }
        let time = now()
        let target = ramp.target(at: time)
        wristTarget = target
        model.link.setWristTarget(target)
        if ramp.atLimit(at: time), !wristLimitCued {
            wristLimitCued = true
            model.raise(.limit(.wrist))
        }
    }

    /// A mode or hand change, refused while a hold runs: the pad goes away, so nothing on it stays down.
    private func releaseAllButtons() {
        buttons.holdEnded()
        for button in buttons.down { _ = buttons.release(button) }
        restoreButtonSpeed()
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
        case .tapStill: return .tapStill
        case .tapLetGo: return .tapLetGo
        case .tapViewAbove: return .tapViewAbove
        case .notTracking: return .notTracking
        case .posture: return .posture
        case .letGoFirst: return .letGoFirst
        case .notStopped: return .notStopped
        case .settingsOpen, .tooHot, .resetFirst: return .deadInput
        case .useUpperKey: return .useUpperKey
        case .outsideWorkArea: return .outsideWorkArea
        case .noArmData: return .noArmData
        }
    }
}
