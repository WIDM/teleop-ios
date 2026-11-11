import Observation
import simd
import SwiftUI
import TeleopCore

@Observable
final class AppModel {
    var session: TeleopSession
    @ObservationIgnored private let cues: CuePlayer
    @ObservationIgnored private let pose: () -> simd_float4x4?
    @ObservationIgnored private let nowMs: () -> Int
    @ObservationIgnored private var holdStartPose: simd_float4x4?
    @ObservationIgnored private var pendingServerCause: StopCause?
    @ObservationIgnored let link: LiveLinkController
    @ObservationIgnored private var narrator = RecorderNarrator()
    /// Why the press the session just refused was refused, when the app decided it.
    @ObservationIgnored private var pendingRefusal: Refusal?
    /// The last STOP reached a connection that was up.
    @ObservationIgnored private var stopReached = true
    /// STOP was pressed with no connection up: `estop` goes out first after the next `welcome`.
    @ObservationIgnored private var stopOwed = false
    /// A hold was engaged when the link was last lost, so a stopped server found on reconnect is the link's doing.
    @ObservationIgnored private var holdEngagedAtLoss = false
    /// The built-in demo's hold count, for its GO.
    @ObservationIgnored private var demoHold = 0
    /// Real server instead of the built-in demo. Changing it drops the current link and starts the other,
    /// so no session spans both.
    var liveLink: Bool {
        get { session.state.liveLink }
        set {
            guard newValue != session.state.liveLink, !session.state.emergencyStop else { return }
            link.closeQuietly()
            session.state.liveLink = newValue
            send(.switchLink)
            UserDefaults.standard.set(newValue, forKey: Self.liveLinkKey)
        }
    }
    static let liveLinkKey = "liveLink"
    static let serverAddressKey = "serverAddress"
    /// Set the first time standby is reached: after the tutorial, or by any other way such as releasing an E-stop
    /// pressed during it. From then on the app opens on standby.
    static let firstRunDoneKey = "firstRunDone"
    /// UI tests only: `-recordHaptics YES` shows requested haptics to XCUITest, which cannot feel them.
    private(set) var hapticLog: [String]? = UserDefaults.standard.bool(forKey: "recordHaptics") ? [] : nil
    var language: AppLanguage = L10n.language {
        didSet {
            L10n.language = language
            language.save()
        }
    }
    /// Live link only, during an arm hold: metres right, forward and up that the arm is being asked to move.
    private(set) var holdOffset: SIMD3<Float>?
    /// How the phone is held, as of the last `refreshPosture`.
    private(set) var posture: PhonePosture = .unknown
    /// Live link only: where the cube or the goal is from the gripper.
    private(set) var guidance: Guidance?
    /// True while the command is held back so the arm can catch up with the phone.
    private(set) var catchingUp = false
    /// Why E-stop is latched, for S4. Nil when not latched.
    private(set) var stopCause: StopCause?
    /// Developer mode log: actions and haptics with times, newest last.
    private(set) var debugLog: [String] = []
    /// The newest `state` from either connection: measured wrist and gripper angles, the arm, the recorder.
    /// Nil before the first.
    private(set) var serverState: ServerState?
    /// What the server's recorder is doing, for the REC line.
    private(set) var recorder: RecorderDisplay = .unknown
    /// The exits the emergency-stop state may offer.
    private(set) var stopExits = StopExits.offered(recorder: nil, practice: true)
    /// A close ended in contact and nothing has opened since, no scene reset and no new server run. While true a
    /// second close is refused (`raise(.limit(.alreadyGripping))`).
    private(set) var gripping = false

    /// - Parameters:
    ///   - sounds, speech: nil plays them on the device, except in the unit-test host, which stays silent.
    ///   - makeObserverTransport: the listening connection's socket; `makeTransport` when nil.
    init(
        start: Route = .s2,
        haptics: HapticsPlaying = HapticsController(),
        sounds: SoundPlaying? = nil,
        speech: SpeechPlaying? = nil,
        pose: @escaping () -> simd_float4x4? = { PoseTracker.shared.current },
        liveLink: Bool = UserDefaults.standard.bool(forKey: AppModel.liveLinkKey),
        makeTransport: @escaping (URL) -> LinkTransport = { WebSocketTransport(url: $0) },
        makeObserverTransport: ((URL) -> LinkTransport)? = nil,
        nowMs: @escaping () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }
    ) {
        var state = FakeTeleopState()
        state.liveLink = liveLink
        if liveLink, let saved = UserDefaults.standard.string(forKey: Self.serverAddressKey) {
            state.serverAddress = saved
        }
        session = TeleopSession(state: state, start: start)
        let audible = Self.opensSavedServerAtLaunch()
        cues = CuePlayer(
            haptics: haptics, sounds: sounds ?? (audible ? SoundPlayer() : NoSounds()),
            speech: speech ?? (audible ? SpeechPlayer() : NoSpeech()), nowMs: nowMs
        )
        self.pose = pose
        self.nowMs = nowMs
        link = LiveLinkController(makeTransport: makeTransport, makeObserverTransport: makeObserverTransport, pose: pose, nowMs: nowMs)
        stopExits = StopExits.offered(recorder: nil, practice: !liveLink)
        cues.currentHold = { [weak self] in self?.currentHold }
        cues.onLog = { [weak self] in self?.log("~ \($0)") }
        link.onFeedback = { [weak self] in self?.raise($0) }
        link.onState = { [weak self] in self?.stateArrived($0) }
        link.onWelcome = { [weak self] in self?.welcomed(session: $0) }
        link.onGripping = { [weak self] in self?.gripping = $0 }
        link.onAction = { [weak self] in self?.fromServer($0) }
        link.onLog = { [weak self] in self?.log($0) }
        link.onOffset = { [weak self] in self?.holdOffset = $0 }
        link.onCatchingUp = { [weak self] in
            // Set only on a change: this runs 30 times a second and every write redraws the readout.
            if self?.catchingUp != $0 { self?.catchingUp = $0 }
        }
        link.onGuidance = { [weak self] in
            if self?.guidance != $0 { self?.guidance = $0 }
        }
        link.onServerStop = { [weak self] in self?.pendingServerCause = StopCause(serverReason: $0) }
        // UI tests only: `-startConnected YES` marks the link live without navigating,
        // so the launch route stays put and control input is accepted.
        if UserDefaults.standard.bool(forKey: "startConnected") { session.state.markConnected() }
        // UI tests only: `-startBlocked YES` starts with commands blocked, as a slow live link does.
        // The built-in demo has no latency of its own, so there is no other way to reach that state without a server.
        if UserDefaults.standard.bool(forKey: "startBlocked") { session.state.commandsBlocked = true }
        // UI tests only: `-startConnectionLost YES` starts as a dropped live link leaves things, with the notice on S1.
        // The built-in demo cannot drop its link.
        if UserDefaults.standard.bool(forKey: "startConnectionLost") {
            session.state.markDisconnected()
            session.state.connectionLost = true
        }
        // UI tests and screenshots only: `-demoGuidance YES` shows the task map without a server.
        if UserDefaults.standard.bool(forKey: "demoGuidance") {
            guidance = Guidance.make(
                arm: SIMD3(0.021, -0.141, 0.160), cube: SIMD3(0.005, -0.200, 0.1025),
                goal: SIMD3(0.075, -0.200, 0.1035), gripper: .open
            )
        }
    }

    func send(_ action: TeleopAction) {
        // A reset is refused while anything is held: the operator lets go first.
        if action == .resetScene, Self.engaged(session.state) {
            log("→ \(action) refused: something is held")
            raise(.refused(.letGoFirst))
            return
        }
        perform(action, fromServer: false)
    }

    /// Plays an event's cue: felt, heard or both. Other parts raise their own here, as the input does for a dead
    /// input (`.refused(.deadInput)`) or a second close while gripping (`.limit(.alreadyGripping)`).
    func raise(_ event: FeedbackEvent) {
        cues.raise(event)
    }

    /// The cues decided so far, newest last.
    var cueLog: [CueLogEntry] { cues.log }

    func foregroundChanged() { link.foregroundChanged() }

    /// Reads how the phone is held, from the same pose the arm follows. Called a few times a second on
    /// control screens. A change between held right and not is felt: one short buzz for right, two for not.
    func refreshPosture() {
        let now = PhonePosture.of(pose(), previous: posture)
        guard now != posture else { return }
        posture = now
    }

    /// Live link only: opens the socket to the saved server, so standby is ready without a trip to the connect
    /// screen. Called at launch and when the Settings switch turns the real server on.
    func trySavedServer() {
        guard session.state.liveLink, !session.state.connected, !link.isOpen else { return }
        _ = link.connect(to: session.state.serverAddress)
    }

    /// False when the app is only the host process of the unit tests. That launch reads whatever Real server
    /// setting and address the simulator has saved, and must never reach a live server.
    static func opensSavedServerAtLaunch(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["XCTestConfigurationFilePath"] == nil
    }

    /// S1 Connect. Fake link: connected at once. Live link: opens the socket; `linkUp` or `linkLost` follows.
    func connect() {
        guard session.state.liveLink else {
            send(.connect)
            return
        }
        let address = session.state.serverAddress
        if link.connect(to: address) {
            session.state.serverInputError = false
            UserDefaults.standard.set(address, forKey: Self.serverAddressKey)
        } else {
            session.state.serverInputError = true
        }
    }

    /// Server-side changes. A server E-stop latches here too, but is not echoed back.
    private func fromServer(_ action: TeleopAction) {
        if action == .stop, session.state.emergencyStop { return }
        if action == .linkLost, session.state.connected {
            let engaged = Self.engaged(session.state)
            holdEngagedAtLoss = engaged
            narrator.linkLost()
            raise(.linkLost(holdEngaged: engaged))
        }
        perform(action, fromServer: true)
    }

    /// A `state` from either connection.
    private func stateArrived(_ state: ServerState) {
        if serverState != state { serverState = state }
        let now = nowMs()
        for event in narrator.observe(state, moving: Self.engaged(session.state), at: now) + narrator.tick(at: now) {
            raise(event)
        }
        refreshRecorder()
    }

    /// The control connection's welcome. A STOP pressed while no connection was up goes out first.
    private func welcomed(session run: String?) {
        narrator.welcomed(session: run)
        guard stopOwed else { return }
        stopOwed = false
        narrator.emergencyStopLearned()
        link.estop()
        log("link: the STOP pressed while the link was down is sent now")
        raise(.emergencyStop(.button, takeDiscarded: narrator.stopDiscardsTake))
    }

    private func refreshRecorder() {
        if recorder != narrator.display { recorder = narrator.display }
        let exits = StopExits.offered(recorder: narrator.recorder, practice: !session.state.liveLink)
        if stopExits != exits { stopExits = exits }
    }

    /// The hold the feedback belongs to: the link's on a real server, the demo's own count otherwise.
    private var currentHold: Int? {
        if session.state.liveLink { return link.engagedHold }
        return Self.engaged(session.state) ? demoHold : nil
    }

    private static func engaged(_ state: FakeTeleopState) -> Bool {
        state.armMoving || state.gripperMoving != nil || state.jawTurning != nil
    }

    private func perform(_ action: TeleopAction, fromServer: Bool) {
        stopReached = true
        let before = session.state
        let routeBefore = session.route
        let wasMoving = before.armMoving
        session.perform(action)
        if routeBefore != .p4, session.route == .p4 {
            UserDefaults.standard.set(true, forKey: Self.firstRunDoneKey)
        }
        if session.state.liveLink { driveLink(action, before: before, fromServer: fromServer) }
        if !session.state.armMoving { holdOffset = nil }
        if !before.emergencyStop, session.state.emergencyStop {
            stopCause = fromServer ? (pendingServerCause ?? .server("unknown")) : .button
        } else if !session.state.emergencyStop {
            stopCause = nil
        }
        pendingServerCause = nil
        // The latency probe ticks every second; logging it would bury everything else.
        if !Self.isLatency(action) { log("→ \(action)") }
        logPose(wasMoving: wasMoving)
        let commands = session.drainHaptics()
        for command in commands {
            hapticLog?.append(Self.logName(command))
            log("~ \(Self.logName(command))")
            feedback(for: command, before: before)
        }
        pendingRefusal = nil
        if commands.isEmpty, Self.isPress(action), !Self.engaged(before), !Self.engaged(session.state) {
            // The session ignores a press while stopped or with no link; the operator still hears why.
            if before.emergencyStop {
                raise(.refused(.emergencyStop))
            } else if !before.connected {
                raise(.refused(.noLink))
            }
        }
        if !session.state.liveLink, !Self.engaged(before), Self.engaged(session.state) {
            // The demo has no server to accept the hold: it is live at once.
            demoHold += 1
            raise(.holdLive(hold: demoHold))
        }
        refreshRecorder()
    }

    /// The session asks for its own haptic commands; the operator feels and hears the events they stand for.
    private func feedback(for command: HapticCommand, before: FakeTeleopState) {
        switch command {
        case .play(.emergencyLoop):
            guard !session.state.liveLink || stopReached else {
                stopOwed = true
                raise(.refused(.notStopped))
                return
            }
            narrator.emergencyStopLearned()
            raise(.emergencyStop(emergencyCause, takeDiscarded: session.state.liveLink && narrator.stopDiscardsTake))
        case .cancel:
            cues.stopHaptics()
        case .play(.stopReleased):
            raise(.ready)
        case .play(.commandBlocked):
            raise(.refused(pendingRefusal ?? (before.commandsBlocked ? .slowLink : .deadInput)))
        case .play(.gripperClosed), .play(.gripperOpened), .play(.postureOk), .play(.postureOff):
            // A gripper press is live when the server accepts it (GO); the posture is a reason for a refusal.
            break
        }
    }

    private var emergencyCause: EmergencyCause {
        switch stopCause {
        case .button, nil: return .button
        case .armBehind: return .behind
        case .onConnect: return holdEngagedAtLoss ? .link : .onConnect
        case .server: return .other
        }
    }

    private static func isPress(_ action: TeleopAction) -> Bool {
        switch action {
        case .holdArmStart, .gripperStart, .turnStart: return true
        default: return false
        }
    }

    /// Mirrors what the session just decided onto the wire. The session decides; the link only follows.
    private func driveLink(_ action: TeleopAction, before: FakeTeleopState, fromServer: Bool) {
        let after = session.state
        // E-stop goes out first. A server-side E-stop is not echoed, but our own hold still has to end.
        if !before.emergencyStop, after.emergencyStop, !fromServer { stopReached = link.estop() }
        if before.armMoving, !after.armMoving { link.endHold() }
        if before.emergencyStop, !after.emergencyStop { link.estopReset() }
        if !before.armMoving, after.armMoving {
            let params = PoseParams(gain: after.sensitivity, smoothing: after.smoothing)
            let held = PhonePosture.of(pose(), previous: posture)
            if held == .tilted || !link.startHold(params) {
                log("link: hold not started (\(held == .tilted ? "phone held wrong" : "no tracking or link"))")
                pendingRefusal = held == .tilted ? .posture : (held == .unknown ? .notTracking : .noLink)
                session.perform(.holdArmEnd)
                session.pendingCue(.commandBlocked)
            }
        }
        if before.jawTurning != after.jawTurning {
            if let direction = after.jawTurning {
                if !link.startTurn(direction) {
                    log("link: jaw turn not started (no link)")
                    pendingRefusal = .noLink
                    session.perform(.turnEnd)
                    session.pendingCue(.commandBlocked)
                }
            } else {
                link.stopTurn()
            }
        }
        if before.gripperMoving != after.gripperMoving {
            if let target = after.gripperMoving { link.startGripper(target) } else { link.stopGripper() }
        }
        switch action {
        case .resetScene where before.connected && !before.emergencyStop:
            link.resetScene()
        case .disconnect:
            link.closeQuietly()
            holdEngagedAtLoss = false
        case .switchLink:
            link.closeQuietly()
            holdEngagedAtLoss = false
            trySavedServer()
        default:
            break
        }
    }

    private static func isLatency(_ action: TeleopAction) -> Bool {
        if case .linkLatency = action { return true }
        return false
    }

    func log(_ line: String) {
        debugLog.append(Self.clock.string(from: Date()) + " " + line)
        if debugLog.count > 40 { debugLog.removeFirst(debugLog.count - 40) }
    }

    func clearLog() { debugLog = [] }

    private func logPose(wasMoving: Bool) {
        let moving = session.state.armMoving
        if !wasMoving, moving {
            holdStartPose = pose()
            if holdStartPose == nil { log("pose: no tracking") }
        } else if wasMoving, !moving {
            if let start = holdStartPose, let end = pose() { log(PoseDelta(from: start, to: end).logLine) }
            holdStartPose = nil
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static func logName(_ command: HapticCommand) -> String {
        switch command {
        case .play(let cue): return "\(cue)"
        case .cancel: return "cancel"
        }
    }

    /// A fresh install opens on the permissions screen, every later launch on standby.
    /// UI tests and screenshots can open any screen with `-startRoute <raw value>`.
    static func startRoute(from defaults: UserDefaults = .standard) -> Route {
        if let route = defaults.string(forKey: "startRoute").flatMap(Route.init(rawValue:)) { return route }
        return defaults.bool(forKey: firstRunDoneKey) ? .p4 : .s2
    }
}

/// What latched E-stop, shown on S4 so a stop the operator did not ask for is not a mystery.
enum StopCause: Equatable {
    /// STOP was pressed on the phone.
    case button
    /// The server stopped because the arm fell too far behind the commanded position.
    case armBehind
    /// The server was already stopped when the link came up, as it is after a connection dropped mid-command.
    case onConnect
    case server(String)

    init(serverReason: String) {
        switch serverReason {
        case "pose_tracking_safety_stop", "tracking_safety_stop": self = .armBehind
        case "on_connect": self = .onConnect
        default: self = .server(serverReason)
        }
    }

    var text: String {
        switch self {
        case .button: return L10n.string("stop.cause_button")
        case .armBehind: return L10n.string("stop.cause_arm_behind")
        case .onConnect: return L10n.string("stop.cause_on_connect")
        case .server(let reason): return String(format: L10n.string("stop.cause_server"), reason)
        }
    }
}
