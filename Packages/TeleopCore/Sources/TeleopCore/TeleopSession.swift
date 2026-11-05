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
    case simulateHighLatency
    case simulateNormalLatency
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
    case openBase
    case releaseBase
    case openFallback
    case startFallbackRecording
    case toggleGripper
    case holdArmStart
    case holdArmEnd
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

    public mutating func perform(_ action: TeleopAction) {
        switch action {
        case .modeNext:
            switch state.mode {
            case .cloud:
                state.simulateCloudPass()
                go(.p2)
            case .onSite:
                state.markConnected()
                go(.s2)
            }
        case .cloudEnterStandby:
            go(.s2)
        case .cloudSimulateFail:
            state.simulateCloudFail()
            go(.p3)
        case .cloudRecheck:
            state.simulateCloudPass()
            go(.p2)
        case .cloudUseOnSite:
            state.selectOnSite()
            state.markConnected()
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
        case .simulateHighLatency:
            state.simulateHighLatency()
            go(.p6)
        case .simulateNormalLatency:
            state.simulateNormalLatency()
            go(.p4)
        case .connect:
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
            state.emergencyStop = true
            state.armMoving = false
            pendingHaptics.append(.play(.emergencyLoop))
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
        case .saveRecording, .discardRecording, .releaseBase:
            go(.p4)
        case .openBase:
            go(.s3m)
        case .openFallback:
            go(.s5)
        case .startFallbackRecording:
            go(.s5a)
        case .toggleGripper:
            guard acceptsControl else { return }
            // H8: the arm is moving, so the gripper cannot toggle.
            guard canControl, !state.armMoving else {
                pendingHaptics.append(.play(.commandBlocked))
                return
            }
            state.toggleGripper()
            pendingHaptics.append(.play(state.gripper == .closed ? .gripperClosed : .gripperOpened))
        case .holdArmStart:
            guard acceptsControl else { return }
            guard canControl else {
                pendingHaptics.append(.play(.commandBlocked))
                return
            }
            state.armMoving = true
        case .holdArmEnd:
            // Release always stops, even if the session got blocked while held.
            state.armMoving = false
        }
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
