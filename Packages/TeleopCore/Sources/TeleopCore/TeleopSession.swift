/// User intents raised by screens. Each one maps to a state change and/or a navigation step.
public enum TeleopAction: Equatable, Sendable {
    case modeNext
    case cloudEnterStandby
    case cloudSimulateFail
    case cloudRecheck
    case cloudUseOnSite
    case permissionsContinue
    case tutorialSkip
    case tutorialNext(step: Int)
    case openConnection
    case closeConnection
    case openKeyboard
    case keyboardDone
    case changeServer
    case connect
    case disconnect
    case s1Back
    case reconnect
    case backToConnect
    case back
    case stop
    case releaseStop
    case openSettings
    case settingsDone
    case replayTutorial
    case openRecording
    case recordingAppeared
    case recordingTick
    case stopRecording
    case saveRecording
    case discardRecording
    case openFallback
    case startFallbackRecording
    /// The gripper control is pressed: travel toward open or closed until `gripperEnd`.
    case gripperStart(GripperState)
    case gripperEnd
    /// A wrist control is pressed: the wrist rolls or pitches toward `direction` until `turnEnd`.
    case turnStart(TurnDirection)
    case turnEnd
    case holdArmStart
    case holdArmEnd
    case resetScene
    case switchMode
    /// Live link only: the server welcomed us and sent its state.
    case linkUp(gripper: GripperState?)
    /// Live link only: the socket closed, failed to open, or the server went quiet.
    case linkLost
    /// Live link only: measured round trip in milliseconds.
    case linkLatency(ms: Int)
}

/// Navigation plus fake state, driven only through `perform`.
public struct TeleopSession: Equatable, Sendable {
    public var state: FakeTeleopState
    public private(set) var navigator: TeleopNavigator
    public private(set) var pendingHaptics: [HapticCommand] = []
    /// Screen that opened P5, so Close can return to it. Cleared once navigation leaves the P5 cluster.
    private var connectionOrigin: Route?

    public init(state: FakeTeleopState = FakeTeleopState(), start: Route = .p1) {
        self.state = state
        navigator = TeleopNavigator(start: start)
    }

    public var route: Route { navigator.current }

    public mutating func drainHaptics() -> [HapticCommand] {
        defer { pendingHaptics = [] }
        return pendingHaptics
    }

    /// For a refusal decided outside the session, such as a hold with no tracked phone pose.
    public mutating func pendingCue(_ cue: HapticCue) {
        pendingHaptics.append(.play(cue))
    }

    public mutating func perform(_ action: TeleopAction) {
        switch action {
        case .modeNext:
            switch state.mode {
            case .cloud:
                cloudPass()
                go(.p2)
            case .onSite:
                assumeConnected()
                go(.s2)
            }
        case .cloudEnterStandby:
            go(.s2)
        case .cloudSimulateFail:
            state.simulateCloudFail()
            go(.p3)
        case .cloudRecheck:
            cloudPass()
            go(.p2)
        case .cloudUseOnSite:
            state.selectOnSite()
            assumeConnected()
            go(.s2)
        case .permissionsContinue:
            go(state.tutorialDone ? .p4 : .t1)
        case .tutorialSkip:
            state.tutorialDone = true
            go(.p4)
        case .tutorialNext(let step):
            switch step {
            case 1: go(.t2)
            case 2: go(.t3)
            default:
                state.tutorialDone = true
                go(.p4)
            }
        case .openConnection:
            if route != .p5 { connectionOrigin = route }
            go(.p5)
        case .closeConnection:
            // E-stop latched: S4 must never be hidden. No origin: fall back to P4.
            go(state.emergencyStop ? .s4 : (connectionOrigin ?? .p4))
        case .openKeyboard:
            go(.p7)
        case .keyboardDone:
            go(.p5)
        case .changeServer:
            go(.s1)
        case .connect:
            // Live link: the app opens the socket and `linkUp` reports success.
            guard !state.liveLink else { return }
            state.markConnected()
            go(.p5)
        case .disconnect:
            state.markDisconnected()
            go(.s7)
        case .s1Back:
            go(.p5)
        case .reconnect, .backToConnect:
            go(.s1)
        case .back:
            navigator.back()
        case .stop:
            // Already latched means the long buzz is playing; a second loop could outlive the release.
            if !state.emergencyStop { pendingHaptics.append(.play(.emergencyLoop)) }
            state.emergencyStop = true
            state.armMoving = false
            state.stopGripper()
            state.stopTurn()
            go(.s4)
        case .releaseStop:
            state.emergencyStop = false
            // H15: the long buzz ends and one short buzz confirms the release.
            pendingHaptics.append(.cancel)
            pendingHaptics.append(.play(.stopReleased))
            go(.p4)
        case .openSettings:
            go(.s6)
        case .settingsDone:
            go(.p4)
        case .replayTutorial:
            state.tutorialDone = false
            go(.t1)
        case .openRecording:
            go(.s3a)
        case .recordingAppeared:
            if !state.isRecording { state.startRecording() }
        case .recordingTick:
            state.tickRecording()
        case .stopRecording:
            state.stopRecording()
            go(.s3b)
        case .saveRecording, .discardRecording:
            go(.p4)
        case .openFallback:
            go(.s5)
        case .startFallbackRecording:
            go(.s5a)
        case .gripperStart(let target):
            guard acceptsControl else { return }
            // H8: the arm is moving, so the gripper cannot move.
            guard canControl, !state.armMoving else {
                pendingHaptics.append(.play(.commandBlocked))
                return
            }
            // One cue per direction, so a key that repeats while held does not buzz again.
            if state.gripperMoving != target {
                pendingHaptics.append(.play(target == .closed ? .gripperClosed : .gripperOpened))
            }
            // The server runs one held control at a time: the gripper takes over from a jaw turn.
            state.stopTurn()
            state.moveGripper(toward: target)
        case .gripperEnd:
            // Release always stops, even if the session got blocked while held.
            state.stopGripper()
        case .turnStart(let direction):
            guard acceptsControl else { return }
            // The arm is moving, so the jaws cannot turn.
            guard canControl, !state.armMoving else {
                pendingHaptics.append(.play(.commandBlocked))
                return
            }
            state.stopGripper()
            state.turnJaws(toward: direction)
        case .turnEnd:
            // Release always stops, even if the session got blocked while held.
            state.stopTurn()
        case .holdArmStart:
            guard acceptsControl else { return }
            guard canControl else {
                pendingHaptics.append(.play(.commandBlocked))
                return
            }
            // The server runs one held control at a time: the arm takes over from the gripper and a jaw turn.
            state.stopGripper()
            state.stopTurn()
            state.armMoving = true
        case .holdArmEnd:
            // Release always stops, even if the session got blocked while held.
            state.armMoving = false
        case .resetScene:
            // Not refused while latency-blocked: clearing that block is part of the reset (P6 -> P4).
            guard acceptsControl else { return }
            state.resetScene()
            if route == .p6 { go(.p4) }
        case .switchMode:
            // Never while E-stopped: P1 would hide S4.
            guard !state.emergencyStop else { return }
            state.leaveSession()
            connectionOrigin = nil
            navigator = TeleopNavigator(start: .p1)
        case .linkUp(let gripper):
            guard state.liveLink else { return }
            state.markConnected()
            state.heartbeatOk = true
            state.serverInputError = false
            if let gripper { state.gripper = gripper }
            if route == .s1 { go(.p5) }
        case .linkLost:
            guard state.liveLink else { return }
            let wasConnected = state.connected
            state.markDisconnected()
            state.commandsBlocked = false
            if !wasConnected {
                // A failed attempt: say so on the connect screen, go nowhere.
                if route == .s1 { state.serverInputError = true }
            } else if !state.emergencyStop, BackStackRules.controlRoutes.contains(route) {
                // E-stop latched: S4 must never be hidden.
                go(.s7)
            }
        case .linkLatency(let ms):
            guard state.liveLink, state.connected else { return }
            // One slow sample is noise (a stalled radio, the app waking up). Two in a row is a slow link.
            let slow = ms >= FakeTeleopState.blockLatencyMs
            let confirmed = slow && (state.commandsBlocked || state.latencyMs >= FakeTeleopState.blockLatencyMs)
            state.latencyMs = ms
            if confirmed {
                state.commandsBlocked = true
                state.armMoving = false
                state.stopGripper()
                state.stopTurn()
                if route == .p4 { go(.p6) }
            } else if !slow {
                state.commandsBlocked = false
                if route == .p6 { go(.p4) }
            }
        }
    }

    /// Fake link: reaching a control screen means connected. Live link: only `linkUp` does that.
    private mutating func assumeConnected() {
        if !state.liveLink { state.markConnected() }
    }

    private mutating func cloudPass() {
        let wasConnected = state.connected
        state.simulateCloudPass()
        if state.liveLink { state.connected = wasConnected }
    }

    /// Inputs are ignored outright while E-stopped or disconnected: no motion, no haptic.
    private var acceptsControl: Bool {
        state.connected && !state.emergencyStop
    }

    /// Control actions (gripper, motion) are refused while E-stopped, disconnected or latency-blocked.
    private var canControl: Bool {
        state.connected && !state.emergencyStop && !state.commandsBlocked
    }

    private mutating func go(_ route: Route) {
        if ![.p5, .p7, .s1].contains(route) { connectionOrigin = nil }
        navigator.navigate(to: route)
    }
}
