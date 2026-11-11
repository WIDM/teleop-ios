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
    /// Real server instead of the practice demo. Not kept across launches: every launch is on the real server.
    /// Only `startPractice` and `leavePractice` change it.
    var liveLink: Bool { session.state.liveLink }
    /// UI tests only: `-liveLink NO` launches in practice. It was once a saved setting; a saved value is ignored.
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
    /// On a real server: a close ended in contact and nothing has opened since, no scene reset and no new server run.
    /// While true a second close is refused (`raise(.limit(.alreadyGripping))`). Practice has no jaws to grip with.
    var gripping: Bool { session.state.liveLink && link.gripping }
    /// Everything the operating screen draws.
    private(set) var operating: OperatingDisplay
    /// UI tests only: `-operatingFixture <name>` shows that display, and nothing overwrites it.
    @ObservationIgnored private let fixture: OperatingDisplay?
    private var modeSetting: ControlMode
    private var handSetting: Hand
    private var taskAidSetting: Bool
    private var surfaceLayout: SurfaceLayout?
    @ObservationIgnored let profile = RobotProfile.so101Simulator
    /// Turns the keys, touches, the phone's attitude and the pad's buttons into commands.
    @ObservationIgnored private(set) var controller: OperatingController!
    /// The measured flex in the first state after the last reset, for the tilt window (I-8.3).
    @ObservationIgnored private var flexAtReset: Double?
    @ObservationIgnored private var flexAtResetOwed = true
    @ObservationIgnored private var lastEpisode: Int?
    @ObservationIgnored private var lastWelcomeSession: String?
    /// The newest refusal the operator heard, and when, for the one-second display.
    @ObservationIgnored private var lastRefusal: (refusal: Refusal, atMs: Int)?
    /// The newest saved take, and when, for the two-second display.
    @ObservationIgnored private var lastSaved: (count: Int, atMs: Int)?
    /// The arm hold being started comes from a button, not the phone.
    @ObservationIgnored private var pendingButtonHold = false
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []

    static let controlModeKey = "controlMode"
    static let handKey = "hand"
    static let taskAidKey = "taskAid"
    static let operatingFixtureKey = "operatingFixture"

    /// Settings → Control → Mode, kept across launches. A change while anything is engaged is refused.
    var controlMode: ControlMode {
        get { modeSetting }
        set {
            guard newValue != modeSetting else { return }
            guard !Self.engaged(session.state), !controller.isEngaged else {
                raise(.refused(.letGoFirst))
                return
            }
            modeSetting = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.controlModeKey)
            controller.modeChanged(newValue, hand: handSetting)
            refreshOperating()
        }
    }

    /// Settings → Hand, kept across launches.
    var hand: Hand {
        get { handSetting }
        set {
            guard newValue != handSetting else { return }
            handSetting = newValue
            UserDefaults.standard.set(newValue == .left ? "left" : "right", forKey: Self.handKey)
            controller.modeChanged(modeSetting, hand: newValue)
            refreshOperating()
        }
    }

    /// Settings → Task aid, kept across launches. On by default.
    var taskAid: Bool {
        get { taskAidSetting }
        set {
            guard newValue != taskAidSetting else { return }
            taskAidSetting = newValue
            UserDefaults.standard.set(newValue, forKey: Self.taskAidKey)
            refreshOperating()
        }
    }

    /// - Parameters:
    ///   - haptics, sounds, speech: nil plays them on the device, except in the unit-test host and under the UI tests'
    ///     `-quietCues YES`, which stay silent.
    ///   - makeObserverTransport: the listening connection's socket; `makeTransport` when nil.
    ///   - clientName: how the app names itself to the server; the bundle's version and build unless a test passes one.
    init(
        start: Route = .s2,
        haptics: HapticsPlaying? = nil,
        sounds: SoundPlaying? = nil,
        speech: SpeechPlaying? = nil,
        pose: @escaping () -> simd_float4x4? = { PoseTracker.shared.current },
        liveLink: Bool = AppModel.launchesOnTheRealServer(),
        makeTransport: @escaping (URL) -> LinkTransport = { WebSocketTransport(url: $0) },
        makeObserverTransport: ((URL) -> LinkTransport)? = nil,
        nowMs: @escaping () -> Int = { Int(Date().timeIntervalSince1970 * 1000) },
        inputClock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        clientName: String = LiveLinkController.clientName()
    ) {
        var state = FakeTeleopState()
        state.liveLink = liveLink
        // Loaded in practice too, so leaving practice connects to it.
        if let saved = UserDefaults.standard.string(forKey: Self.serverAddressKey) {
            state.serverAddress = saved
        }
        session = TeleopSession(state: state, start: start)
        let defaults = UserDefaults.standard
        let mode = defaults.string(forKey: Self.controlModeKey).flatMap(ControlMode.init(rawValue:)) ?? .screenTurns
        let hand: Hand = defaults.string(forKey: Self.handKey) == "left" ? .left : .right
        let taskAid = defaults.object(forKey: Self.taskAidKey) as? Bool ?? true
        let fixture = defaults.string(forKey: Self.operatingFixtureKey).flatMap(OperatingDisplay.fixture(named:))
        modeSetting = mode
        handSetting = hand
        taskAidSetting = taskAid
        self.fixture = fixture
        operating = fixture ?? OperatingDisplay(
            mode: mode, hand: hand, state: .notConnected(reason: nil), layout: nil, engaged: nil,
            resetCountdown: nil, heldButton: nil, speed: .coarse, recorder: .unknown,
            stopExits: StopExits.offered(recorder: nil, practice: !liveLink), linkUp: false, latencyMs: nil,
            address: state.serverAddress, arm: nil, practice: !liveLink, taskAid: taskAid
        )
        let audible = Self.playsCuesOnTheDevice()
        cues = CuePlayer(
            haptics: haptics ?? (audible ? HapticsController() : NoHaptics()),
            sounds: sounds ?? (audible ? SoundPlayer() : NoSounds()),
            speech: speech ?? (audible ? SpeechPlayer() : NoSpeech()), nowMs: nowMs
        )
        self.pose = pose
        self.nowMs = nowMs
        link = LiveLinkController(
            makeTransport: makeTransport, makeObserverTransport: makeObserverTransport, pose: pose, nowMs: nowMs,
            clientName: clientName
        )
        stopExits = StopExits.offered(recorder: nil, practice: !liveLink)
        cues.currentHold = { [weak self] in self?.currentHold }
        cues.onLog = { [weak self] in self?.log("~ \($0)") }
        link.onFeedback = { [weak self] in self?.raise($0) }
        link.onState = { [weak self] in self?.stateArrived($0) }
        link.onWelcome = { [weak self] in self?.welcomed(session: $0) }
        link.onGripping = { [weak self] _ in self?.refreshOperating() }
        link.onAction = { [weak self] in self?.fromServer($0) }
        link.onLog = { [weak self] in self?.log($0) }
        link.onCatchingUp = { [weak self] in
            // Set only on a change: this runs 30 times a second and every write redraws the readout.
            if self?.catchingUp != $0 {
                self?.catchingUp = $0
                self?.refreshOperating()
            }
        }
        link.onServerStop = { [weak self] in self?.pendingServerCause = StopCause(serverReason: $0) }
        link.onWristStartSent = { [weak self] in self?.controller.wristStartSent() }
        controller = OperatingController(
            model: self, mode: mode, hand: hand, constants: profile.inputConstants, now: inputClock
        )
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
        // A setting from before practice stopped being one.
        UserDefaults.standard.removeObject(forKey: Self.liveLinkKey)
        PoseTracker.shared.onFrame = { [weak self] camera, time in self?.poseFrame(camera, at: time) }
        PoseTracker.shared.onInterruption = { [weak self] in self?.controller.cameraInterrupted($0) }
        controller.startTicking()
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) {
                [weak self] _ in self?.activeChanged(false)
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) {
                [weak self] _ in self?.activeChanged(true)
            },
        ]
        refreshOperating()
    }

    deinit {
        for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
    }

    /// The launch is on the real server, except when a UI test passes `-liveLink NO` for practice.
    static func launchesOnTheRealServer(_ defaults: UserDefaults = .standard) -> Bool {
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        return arguments[liveLinkKey] == nil || defaults.bool(forKey: liveLinkKey)
    }

    // MARK: Operating screen intents

    /// The operating screen's size and safe-area insets, in points, whenever they change.
    func surfaceChanged(width: Double, height: Double, safeTop: Double, safeBottom: Double) {
        let layout = SurfaceLayout(
            width: width, height: height, safeTop: safeTop, safeBottom: safeBottom, constants: profile.inputConstants
        )
        guard layout != surfaceLayout else { return }
        surfaceLayout = layout
        controller.layoutChanged(layout)
        refreshOperating()
    }

    /// One raw touch on the operating screen, with `UITouch.timestamp`.
    func touch(_ sample: TouchSample, at time: TimeInterval) {
        controller.touch(sample, at: time)
    }

    /// Buttons mode: a finger came down on `button`.
    func buttonDown(_ button: ButtonID) {
        controller.buttonDown(button)
    }

    /// Buttons mode: the finger lifted, the touch was cancelled, or the finger slid off `button`.
    func buttonUp(_ button: ButtonID) {
        controller.buttonUp(button)
    }

    /// Buttons mode: the Fine / Coarse switch. Refused while a button is down.
    func selectSpeed(_ speed: ButtonSpeed) {
        controller.selectSpeed(speed)
    }

    /// Practice without a robot: the built-in demo. Never the default and never kept across launches; no message
    /// reaches any server while it runs. Refused while the robot is in emergency stop.
    func startPractice() {
        switchLink(live: false)
    }

    /// Back to the real server at the saved address. Refused while the robot is in emergency stop.
    func leavePractice() {
        switchLink(live: true)
    }

    /// Drops the current link and starts the other, so no session spans both.
    private func switchLink(live: Bool) {
        guard live != session.state.liveLink, !session.state.emergencyStop else { return }
        link.closeQuietly()
        session.state.liveLink = live
        if live, session.state.serverAddress.isEmpty,
           let saved = UserDefaults.standard.string(forKey: Self.serverAddressKey) {
            session.state.serverAddress = saved
        }
        send(.switchLink)
    }

    // MARK: Raw inputs from the device

    /// A volume key's capture event: `down` for began, false for ended or cancelled.
    func keyEvent(_ key: InputKey, down: Bool) {
        controller.key(key, down: down)
    }

    /// An ARKit frame: the camera's transform while tracking is normal, nil otherwise, and the frame's timestamp.
    func poseFrame(_ camera: simd_float4x4?, at time: TimeInterval) {
        guard let camera else { return }
        controller.attitude(PhoneAttitude.portrait(cameraTransform: camera), at: time)
    }

    /// The app became active or left the active state (a call, the home screen, Control Center). Every hold ends, with
    /// its stop, on leaving; inputs held across it stay dead; the link's old latency probes are dropped.
    func activeChanged(_ active: Bool) {
        controller.activeChanged(active)
        link.foregroundChanged()
    }

    // MARK: What the input rules are told

    /// The facts of this moment for the input rules (§2.3 I-5, A-2g, I-8.3).
    func inputFacts() -> InputFacts {
        let s = session.state
        let settingsOpen = session.route == .s6
        let notReady = s.liveLink && (link.resetPending || serverState?.simBusy == true)
        var refusal: InputRefusal?
        if s.emergencyStop {
            refusal = .stopped
        } else if !s.connected {
            refusal = .noLink
        } else if settingsOpen {
            refusal = .settingsOpen
        } else if s.commandsBlocked {
            refusal = .slowLink
        } else if notReady {
            refusal = .wait
        }
        let camera = pose()
        var resetRefusal: InputRefusal?
        if controller.buttons.engaged != nil {
            // The input rules do not see the pad's holds, and the top band is dead while one runs (I-3).
            resetRefusal = .letGoFirst
        } else if !s.connected {
            resetRefusal = .noLink
        } else if settingsOpen {
            resetRefusal = .settingsOpen
        } else if notReady {
            resetRefusal = .wait
        }
        return InputFacts(
            refusal: refusal,
            trackingRefusal: controller.isCameraStopped || camera == nil ? .notTracking : nil,
            translationRefusal: PhonePosture.of(camera) == .tilted ? .posture : nil,
            resetRefusal: resetRefusal,
            gripping: profile.recloseLoosensGrip && gripping,
            wrist: WristReadings(
                rollDeg: serverState?.wristRollDeg, flexDeg: serverState?.wristFlexDeg, flexAtResetDeg: flexAtReset
            ),
            connectionUp: !s.liveLink || link.isUp || link.observerUp
        )
    }

    /// The controller handled an input; what the screen draws may have changed.
    func inputsChanged() {
        refreshOperating()
    }

    /// Buttons mode: a direction button's hold. The link streams the pad's ramp instead of the phone's movement.
    func startButtonTranslation() {
        pendingButtonHold = true
        send(.holdArmStart)
        pendingButtonHold = false
    }

    /// The top band was held 2 s (§6.4): reset the scene. In the stop state the server's reset clears the stop
    /// once it confirms it (`sceneResetDone`), unless STOP is pressed again first; the practice link resets at once.
    func runReset() {
        let s = session.state
        guard s.liveLink else {
            send(.resetScene)
            perform(.sceneResetDone, fromServer: false)
            // In the stop state the first only asked for the reset and the confirmation released the stop; the reset
            // itself, which opens the jaws, runs now.
            if s.emergencyStop { send(.resetScene) }
            controller.sceneReset()
            raise(.ready)
            return
        }
        if s.emergencyStop {
            if link.resetScene() {
                perform(.resetScene, fromServer: false)
            } else {
                raise(.notReset)
            }
        } else {
            send(.resetScene)
        }
    }

    func send(_ action: TeleopAction) {
        // A reset is refused while anything is held: the operator lets go first.
        if action == .resetScene, Self.engaged(session.state) {
            log("→ \(action) refused: something is held")
            raise(.refused(.letGoFirst))
            return
        }
        // §6.5: with a recorder, estop_reset would leave it off, so the release is not offered at all and the reset is
        // the way out of the stop. The screen shows no release then; this keeps the rule whatever sends it.
        if action == .releaseStop, session.state.emergencyStop, !stopExits.exits.contains(.releaseKeepScene) {
            log("→ \(action) refused: the recorder needs a reset")
            raise(.refused(.deadInput))
            return
        }
        perform(action, fromServer: false)
    }

    /// Plays an event's cue: felt, heard or both. Other parts raise their own here, as the input does for a dead
    /// input (`.refused(.deadInput)`) or a second close while gripping (`.limit(.alreadyGripping)`).
    func raise(_ event: FeedbackEvent) {
        cues.raise(event)
        switch event {
        case .refused(let refusal): lastRefusal = (refusal, nowMs())
        case .takeSaved(let count): lastSaved = (count, nowMs())
        default: return
        }
        refreshOperating()
    }

    /// The cues decided so far, newest last.
    var cueLog: [CueLogEntry] { cues.log }

    /// Live link only: opens the socket to the saved server, so standby is ready without a trip to the connect
    /// screen. Called at launch and when practice ends.
    func trySavedServer() {
        guard session.state.liveLink, !session.state.connected, !link.isOpen else { return }
        _ = link.connect(to: session.state.serverAddress)
    }

    /// UI tests only: `-quietCues YES` plays no sound, speech or haptics, which the simulator would put through the
    /// computer's speakers. The cue log still records every cue.
    static let quietCuesKey = "quietCues"

    /// Haptics, sounds and speech play on the device: not in the unit-test host, and not under `-quietCues YES`.
    static func playsCuesOnTheDevice(
        _ defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        opensSavedServerAtLaunch(environment: environment) && !defaults.bool(forKey: quietCuesKey)
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
        refreshOperating()
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
        if let episode = state.episode {
            if let last = lastEpisode, episode != last { sceneWasReset() }
            lastEpisode = episode
        }
        if flexAtResetOwed, !state.estop, !state.simBusy, let flex = state.wristFlexDeg {
            flexAtReset = flex
            flexAtResetOwed = false
        }
        let now = nowMs()
        for event in narrator.observe(state, moving: Self.engaged(session.state), at: now) + narrator.tick(at: now) {
            raise(event)
        }
        refreshRecorder()
    }

    /// The control connection's welcome. A STOP pressed while no connection was up goes out first.
    private func welcomed(session run: String?) {
        narrator.welcomed(session: run)
        // A new server run starts from its own reset pose. A server that names no run cannot tell a reconnect from a
        // new run, so the tilt window keeps counting from the last reset seen (I-8.3).
        if let run, run != lastWelcomeSession {
            lastWelcomeSession = run
            lastEpisode = nil
            sceneWasReset()
        }
        guard stopOwed else { return }
        stopOwed = false
        narrator.emergencyStopLearned()
        link.estop()
        log("link: the STOP pressed while the link was down is sent now")
        raise(.emergencyStop(.button, takeDiscarded: narrator.stopDiscardsTake))
        refreshOperating()
    }

    private func refreshRecorder() {
        if recorder != narrator.display { recorder = narrator.display }
        let exits = StopExits.offered(recorder: narrator.recorder, practice: !session.state.liveLink)
        if stopExits != exits { stopExits = exits }
        refreshOperating()
    }

    /// Recomputes what the operating screen draws, and writes it only on a change: every write redraws.
    private func refreshOperating() {
        guard fixture == nil, let controller else { return }
        let s = session.state
        let display = OperatingDisplay(
            mode: modeSetting, hand: handSetting, state: OperatingRules.state(operatingFacts), layout: surfaceLayout,
            engaged: controller.engagedHold ?? Self.heldControl(s).map(Self.holdKind),
            resetCountdown: controller.resetCountdown, heldButton: controller.buttons.engaged,
            speed: controller.buttons.speed, recorder: recorder, stopExits: stopExits, linkUp: s.connected,
            latencyMs: s.latencyMs, address: s.serverAddress,
            arm: s.liveLink
                ? OperatingRules.arm(serverState, commanded: link.commandedArm, gripping: gripping, profile: profile)
                : nil,
            practice: !s.liveLink, taskAid: taskAidSetting
        )
        if operating != display { operating = display }
    }

    private var operatingFacts: OperatingFacts {
        let s = session.state
        var facts = OperatingFacts()
        facts.connected = s.connected
        facts.connecting = s.liveLink && link.isOpen
        facts.connectionLost = s.connectionLost
        facts.address = s.serverAddress
        facts.emergencyStop = s.emergencyStop
        facts.stopOwed = stopOwed
        facts.stopCause = s.emergencyStop ? emergencyCause : nil
        facts.cameraStopped = controller.isCameraStopped
        facts.commandsBlocked = s.commandsBlocked
        facts.latencyMs = s.latencyMs
        facts.engaged = controller.engagedHold ?? Self.heldControl(s).map(Self.holdKind)
        facts.wristTarget = controller.wristTarget
        facts.wristMeasured = serverState?.wristRollDeg != nil
        facts.catchingUp = catchingUp
        facts.gripping = gripping
        if s.liveLink {
            facts.serverSaving = serverState?.taskSuccess == true || serverState?.activity == .taskSuccess
            facts.serverResetting = link.resetPending || serverState?.activity == .resetting
        }
        facts.lastRefusal = lastRefusal
        facts.lastSaved = lastSaved
        facts.nowMs = nowMs()
        facts.turnLimit = profile.inputConstants.rollClampDeg
        facts.tiltLimit = profile.inputConstants.tiltClampDeg
        return facts
    }

    private static func holdKind(_ control: ControlKind) -> HoldKind {
        switch control {
        case .pose: return .translation
        case .gripper(let target): return .gripper(target)
        case .wrist: return .wrist
        }
    }

    /// A reset, a new episode or a new server run: the tilt window and the wrist lead start again.
    private func sceneWasReset() {
        flexAtReset = nil
        flexAtResetOwed = true
        link.sceneWasReset()
        controller.sceneReset()
    }

    /// The hold the feedback belongs to: the link's on a real server, the demo's own count otherwise.
    private var currentHold: Int? {
        if session.state.liveLink { return link.engagedHold }
        return Self.engaged(session.state) ? demoHold : nil
    }

    private static func engaged(_ state: FakeTeleopState) -> Bool {
        heldControl(state) != nil
    }

    /// The one control held now, if any.
    private static func heldControl(_ state: FakeTeleopState) -> ControlKind? {
        if state.armMoving { return .pose }
        if let target = state.gripperMoving { return .gripper(target) }
        return state.wristMoving ? .wrist : nil
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
        if !session.state.liveLink, let held = Self.heldControl(session.state), held != Self.heldControl(before) {
            // The demo has no server to accept the hold: it is live at once.
            demoHold += 1
            raise(.holdLive(hold: demoHold))
        }
        refreshRecorder()
        controller.sessionChanged()
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
        case .holdArmStart, .gripperStart, .wristStart: return true
        default: return false
        }
    }

    /// Mirrors what the session just decided onto the wire. The session decides; the link only follows.
    private func driveLink(_ action: TeleopAction, before: FakeTeleopState, fromServer: Bool) {
        let after = session.state
        // E-stop goes out first, on every STOP (I-3): with the stop already latched, a reset asked for from it may
        // have cleared the server's stop. A server-side E-stop is not echoed, but our own hold still has to end.
        if action == .stop, !fromServer { stopReached = link.estop() }
        if before.armMoving, !after.armMoving { link.endHold() }
        // Release, keep scene. A reset that cleared the stop needs no estop_reset.
        if before.emergencyStop, !after.emergencyStop, action == .releaseStop { link.estopReset() }
        if !before.armMoving, after.armMoving, pendingButtonHold {
            if !link.startButtonHold({ [weak self] in self?.controller.buttonTarget() }) {
                log("link: button hold not started (no link or a reset)")
                pendingRefusal = link.resetPending ? .notReady : .noLink
                session.perform(.holdArmEnd)
                session.pendingCue(.commandBlocked)
            }
        } else if !before.armMoving, after.armMoving {
            let params = PoseParams(gain: after.sensitivity, smoothing: after.smoothing)
            let held = PhonePosture.of(pose())
            if held == .tilted || !link.startHold(params) {
                log("link: hold not started (\(held == .tilted ? "phone held wrong" : "no tracking, no link or a reset"))")
                if held == .tilted {
                    pendingRefusal = .posture
                } else if link.resetPending {
                    pendingRefusal = .notReady
                } else {
                    pendingRefusal = held == .unknown ? .notTracking : .noLink
                }
                session.perform(.holdArmEnd)
                session.pendingCue(.commandBlocked)
            }
        }
        if before.wristMoving != after.wristMoving {
            if after.wristMoving {
                if !link.startWristHold() {
                    log("link: wrist hold not started (no link or a reset)")
                    pendingRefusal = link.resetPending ? .notReady : .noLink
                    session.perform(.wristEnd)
                    session.pendingCue(.commandBlocked)
                }
            } else {
                link.stopWristHold()
            }
        }
        if before.gripperMoving != after.gripperMoving {
            if let target = after.gripperMoving {
                // The session keeps the press until it is released; nothing goes out, and the operator hears why.
                if !link.startGripper(target), link.resetPending { raise(.refused(.notReady)) }
            } else {
                link.stopGripper()
            }
        }
        switch action {
        case .resetScene where before.connected && !before.emergencyStop:
            link.resetScene()
        case .releaseStop:
            // Released before the link came back: the STOP owed to the server is no longer wanted.
            stopOwed = false
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
