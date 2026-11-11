/// User intents raised by screens. Each one maps to a state change and/or a navigation step.
public enum TeleopAction: Equatable, Sendable {
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
    case back
    case stop
    case releaseStop
    case openSettings
    case settingsDone
    case replayTutorial
    case openFallback
    /// The gripper control is pressed: travel toward open or closed until `gripperEnd`.
    case gripperStart(GripperState)
    case gripperEnd
    /// A wrist control is pressed: the wrist rolls or pitches toward `direction` until `turnEnd`.
    case turnStart(TurnDirection)
    case turnEnd
    /// A wrist hold whose angle follows the phone's rotation (or another source of targets) is engaged, until
    /// `wristEnd`.
    case wristStart
    case wristEnd
    case holdArmStart
    case holdArmEnd
    case resetScene
    /// The server confirmed a scene reset (`ok scene_reset`), or the practice link ran one. A reset asked for in the
    /// stop state (`resetScene` while E-stopped) clears the stop (specification §6.5), so this is the eyes-free way
    /// out of it; a STOP pressed after the request keeps the stop latched.
    case sceneResetDone
    /// The Settings switch between the demo and a real server: the old link is dropped with anything held, and the
    /// new one starts. Sent after `liveLink` has changed.
    case switchLink
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

    /// A session starts at launch, on S2 for a fresh install and on P4 after that.
    public init(state: FakeTeleopState = FakeTeleopState(), start: Route = .s2) {
        self.state = state
        navigator = TeleopNavigator(start: start)
        assumeConnected()
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
            // Disconnect is on S1, so the operator is already where a new connection starts.
            state.markDisconnected()
            state.connectionLost = false
        case .s1Back:
            go(.p5)
        case .back:
            navigator.back()
        case .stop:
            // Already latched means the long buzz is playing; a second loop could outlive the release.
            if !state.emergencyStop { pendingHaptics.append(.play(.emergencyLoop)) }
            // A reset asked for before this STOP must not release it.
            state.resetClearsStop = false
            state.emergencyStop = true
            state.armMoving = false
            state.stopGripper()
            state.stopTurn()
            state.stopWrist()
            go(.s4)
        case .releaseStop:
            state.emergencyStop = false
            state.resetClearsStop = false
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
        case .openFallback:
            go(.s5)
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
            state.stopWrist()
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
            state.stopWrist()
            state.turnJaws(toward: direction)
        case .turnEnd:
            // Release always stops, even if the session got blocked while held.
            state.stopTurn()
        case .wristStart:
            guard acceptsControl else { return }
            // The arm is moving, so the wrist cannot turn.
            guard canControl, !state.armMoving else {
                pendingHaptics.append(.play(.commandBlocked))
                return
            }
            state.stopGripper()
            state.stopTurn()
            state.wristMoving = true
        case .wristEnd:
            // Release always stops, even if the session got blocked while held.
            state.stopWrist()
        case .holdArmStart:
            guard acceptsControl else { return }
            guard canControl else {
                pendingHaptics.append(.play(.commandBlocked))
                return
            }
            // The server runs one held control at a time: the arm takes over from the gripper and a jaw turn.
            state.stopGripper()
            state.stopTurn()
            state.stopWrist()
            state.armMoving = true
        case .holdArmEnd:
            // Release always stops, even if the session got blocked while held.
            state.armMoving = false
        case .resetScene:
            // While E-stopped nothing changes until the server confirms the reset, and that confirmation releases the
            // stop (§6.5).
            if state.emergencyStop {
                if state.connected { state.resetClearsStop = true }
                return
            }
            // Not refused while latency-blocked: clearing that block is part of the reset (P6 -> P4).
            guard acceptsControl else { return }
            state.resetScene()
            if route == .p6 { go(.p4) }
        case .sceneResetDone:
            // Only the reset asked for in the stop state, with no STOP since, releases it.
            guard state.emergencyStop, state.resetClearsStop else { return }
            state.emergencyStop = false
            state.resetClearsStop = false
            // The long buzz ends. "Ready." comes from the server's new episode, not from here.
            pendingHaptics.append(.cancel)
            // As a release does: S4 shows only while the stop is latched, and a connection screen opened from S4
            // must not lead back to it.
            go(.p4)
        case .switchLink:
            // Never while E-stopped: the stop is released first, on the link that set it.
            guard !state.emergencyStop else { return }
            state.leaveSession()
            assumeConnected()
        case .linkUp(let gripper):
            guard state.liveLink else { return }
            state.markConnected()
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
            } else {
                state.connectionLost = true
                // E-stop latched: S4 must never be hidden.
                if !state.emergencyStop, BackStackRules.controlRoutes.contains(route) { go(.s1) }
            }
        case .linkLatency(let ms):
            guard state.liveLink, state.connected else { return }
            // One slow sample is noise (a stalled radio, the app waking up). Two in a row is a slow link.
            let slow = ms >= FakeTeleopState.blockLatencyMs
            let confirmed = slow && (state.commandsBlocked || (state.latencyMs ?? 0) >= FakeTeleopState.blockLatencyMs)
            state.latencyMs = ms
            if confirmed {
                state.commandsBlocked = true
                state.armMoving = false
                state.stopGripper()
                state.stopTurn()
                state.stopWrist()
                if route == .p4 { go(.p6) }
            } else if !slow {
                state.commandsBlocked = false
                if route == .p6 { go(.p4) }
            }
        }
    }

    /// Demo link: connected from the start. Live link: only `linkUp` does that.
    private mutating func assumeConnected() {
        if !state.liveLink { state.markConnected() }
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
