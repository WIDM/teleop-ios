import Observation
import simd
import SwiftUI
import TeleopCore

@Observable
final class AppModel {
    var session: TeleopSession
    @ObservationIgnored private let haptics: HapticsPlaying
    @ObservationIgnored private let pose: () -> simd_float4x4?
    @ObservationIgnored private var holdStartPose: simd_float4x4?
    @ObservationIgnored private var pendingServerCause: StopCause?
    @ObservationIgnored let link: LiveLinkController
    /// Real server instead of the built-in fake. Changing it returns to mode select, so no session spans both.
    var liveLink: Bool {
        get { session.state.liveLink }
        set {
            guard newValue != session.state.liveLink, !session.state.emergencyStop else { return }
            link.closeQuietly()
            send(.switchMode)
            session.state.liveLink = newValue
            UserDefaults.standard.set(newValue, forKey: Self.liveLinkKey)
        }
    }
    static let liveLinkKey = "liveLink"
    static let serverAddressKey = "serverAddress"
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

    init(
        start: Route = .p1,
        haptics: HapticsPlaying = HapticsController(),
        pose: @escaping () -> simd_float4x4? = { PoseTracker.shared.current },
        liveLink: Bool = UserDefaults.standard.bool(forKey: AppModel.liveLinkKey),
        makeTransport: @escaping (URL) -> LinkTransport = { WebSocketTransport(url: $0) },
        nowMs: @escaping () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }
    ) {
        session = TeleopSession(start: start)
        self.haptics = haptics
        self.pose = pose
        link = LiveLinkController(makeTransport: makeTransport, pose: pose, nowMs: nowMs)
        session.state.liveLink = liveLink
        if liveLink, let saved = UserDefaults.standard.string(forKey: Self.serverAddressKey) {
            session.state.serverAddress = saved
        }
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
        // UI tests and screenshots only: `-demoGuidance YES` shows the task map without a server.
        if UserDefaults.standard.bool(forKey: "demoGuidance") {
            guidance = Guidance.make(
                arm: SIMD3(0.021, -0.141, 0.160), cube: SIMD3(0.005, -0.200, 0.1025),
                goal: SIMD3(0.075, -0.200, 0.1035), gripper: .open
            )
        }
    }

    func send(_ action: TeleopAction) {
        perform(action, fromServer: false)
    }

    func foregroundChanged() { link.foregroundChanged() }

    /// Reads how the phone is held, from the same pose the arm follows. Called a few times a second on
    /// control screens. A change between held right and not is felt: one short buzz for right, two for not.
    func refreshPosture() {
        let now = PhonePosture.of(pose(), previous: posture)
        guard now != posture else { return }
        let before = posture
        posture = now
        // The E-stop buzz owns the haptics while latched, and gaining or losing tracking is not a posture change.
        guard !session.state.emergencyStop, before != .unknown, now != .unknown else { return }
        let command = HapticCommand.play(now == .upright ? .postureOk : .postureOff)
        haptics.run(command)
        hapticLog?.append(Self.logName(command))
        log("~ \(Self.logName(command))")
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
        perform(action, fromServer: true)
    }

    private func perform(_ action: TeleopAction, fromServer: Bool) {
        let before = session.state
        let wasMoving = before.armMoving
        session.perform(action)
        if session.state.liveLink { driveLink(action, before: before, fromServer: fromServer) }
        if !session.state.armMoving { holdOffset = nil }
        if !before.emergencyStop, session.state.emergencyStop {
            stopCause = fromServer ? (pendingServerCause ?? .server("unknown")) : .button
        } else if !session.state.emergencyStop {
            stopCause = nil
        }
        pendingServerCause = nil
        // The recording clock and the latency probe tick every second; logging them would bury everything else.
        if action != .recordingTick, !Self.isLatency(action) { log("→ \(action)") }
        logPose(wasMoving: wasMoving)
        for command in session.drainHaptics() {
            haptics.run(command)
            hapticLog?.append(Self.logName(command))
            log("~ \(Self.logName(command))")
        }
    }

    /// Mirrors what the session just decided onto the wire. The session decides; the link only follows.
    private func driveLink(_ action: TeleopAction, before: FakeTeleopState, fromServer: Bool) {
        let after = session.state
        // E-stop goes out first. A server-side E-stop is not echoed, but our own hold still has to end.
        if !before.emergencyStop, after.emergencyStop, !fromServer { link.estop() }
        if before.armMoving, !after.armMoving { link.endHold() }
        if before.emergencyStop, !after.emergencyStop { link.estopReset() }
        if !before.armMoving, after.armMoving {
            let params = PoseParams(
                gain: after.sensitivity, deadbandDegrees: after.deadbandDegrees, smoothing: after.smoothing
            )
            if !link.startHold(params) {
                log("link: hold not started (no tracking or link)")
                session.perform(.holdArmEnd)
                session.pendingCue(.commandBlocked)
            }
        }
        if before.jawTurning != after.jawTurning {
            if let direction = after.jawTurning {
                if !link.startTurn(direction) {
                    log("link: jaw turn not started (no link)")
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
        case .switchMode where session.route == .p1:
            link.closeQuietly()
        case .modeNext, .cloudUseOnSite, .cloudEnterStandby:
            // Entering a session: try the saved server so standby is ready when the user gets there.
            if !after.connected, !link.isOpen { link.connect(to: after.serverAddress) }
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

    static func startRoute(from defaults: UserDefaults = .standard) -> Route {
        defaults.string(forKey: "startRoute").flatMap(Route.init(rawValue:)) ?? .p1
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
