import Observation
import simd
import SwiftUI
import TeleopCore

@Observable
final class AppModel {
    var session: TeleopSession
    @ObservationIgnored private let aimViewsAllowed: Bool
    @ObservationIgnored private let cues: CuePlayer
    @ObservationIgnored let experimentTiming: ExperimentTiming
    @ObservationIgnored private var timingWelcome: [String: Any]?
    @ObservationIgnored let sessionRecord: SessionRecord
    @ObservationIgnored private var recordedTouches: [Int: RecordedTouch] = [:]
    @ObservationIgnored private var lastRecordedLift: TimeInterval?
    @ObservationIgnored private var recentRoundTrips: [Int] = []

    private struct RecordedTouch {
        let point: SIMD2<Double>
        let at: TimeInterval
        let layout: SurfaceLayout
        let panel: SurfaceLayout.Rect?
        var farthestMm = 0.0

        mutating func track(_ sample: TouchSample) {
            let delta = SIMD2(sample.x, sample.y) - point
            farthestMm = max(farthestMm, layout.millimetres(simd_length(delta)))
        }
    }
    @ObservationIgnored private let pose: () -> simd_float4x4?
    @ObservationIgnored private let nowMs: () -> Int
    @ObservationIgnored private var speechActive = true
    private(set) var voiceAxisSession = VoiceAxisSession()
    private(set) var voiceAxisFailure: AxisSpeechFailure?
    @ObservationIgnored private let axisRecognizer: AxisSpeechRecognizing
    @ObservationIgnored private var voiceResume: DispatchWorkItem?
    @ObservationIgnored let voiceActionsPrototype: Bool
    /// Whether the operating screen offers the voice control. Off unless the app is launched with `-voiceEntry YES`:
    /// voice input is an unfinished experiment, and a control on the screen would present it as a feature.
    @ObservationIgnored let voiceEntryShown: Bool =
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["voiceEntry"] as? String == "YES"
    @ObservationIgnored private var voiceMotion: VoiceMotion?

    private enum VoiceGoal {
        case step(offset: SIMD3<Double>, target: SIMD3<Double>)
        case gripper(GripperState)
    }

    private struct VoiceMotion {
        let action: VoiceAction
        let goal: VoiceGoal
        let deadline: Int
        let startStamp: Int
    }
    @ObservationIgnored var onVoiceEvent: ((String, [String: Any]) -> Void)?
    @ObservationIgnored private var readyAfterWelcome = false
    @ObservationIgnored private var holdStartPose: simd_float4x4?
    @ObservationIgnored private var pendingServerCause: StopCause?
    @ObservationIgnored let link: LiveLinkController
    @ObservationIgnored private var narrator = RecorderNarrator()
    /// Why the press the session just refused was refused, when the app decided it.
    @ObservationIgnored private var pendingRefusal: Refusal?
    /// Where a STOP pressed here stands, from the press that latched the stop until the stop is released (J7). Nil
    /// when no stop is latched, or when the server latched it. Reconnect's stop the server did not confirm before its
    /// connection closed is owed too. Observed, for `practiceBlockedReason`.
    private var pressedStop: PressedStop?
    /// The pressed STOP reached no server: `estop` goes out first after the next `welcome`, and until then the robot
    /// is not stopped. Reconnect's owed stop is not released here until then either (`send`).
    private var stopOwed: Bool { pressedStop == .owed }
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
            recordSettings()
        }
    }
    /// True while the command is held back so the arm can catch up with the phone.
    private(set) var catchingUp = false
    /// Why E-stop is latched, for S4. Nil when not latched.
    private(set) var stopCause: StopCause?
    /// The server latched the stop itself while the simulator was paused, and the operator has not been told: said once
    /// when the simulator runs again, with how to go on. True when the stall is known to be its cause (the server
    /// refused this phone's hold `sim_stalled`, or the state that brought the stop said `sim_stalled`): then it is said
    /// to have stopped automatically. False when the cause is unknown, as another client's STOP: then it is told as any
    /// server stop. Nil again once said or the stop is released.
    @ObservationIgnored private var stopLatchedWhilePaused: Bool?
    /// True only while **Reconnect** presses STOP (`stopBeforeReconnect`): the stop it latches has Reconnect as its cause.
    @ObservationIgnored private var reconnectPressingStop = false
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
    private var assistSetting: Bool
    private var lockChoiceSetting: LockChoice
    private var surfaceLayout: SurfaceLayout?
    /// The robot. Tests pass another to run a robot that allows other aids or none.
    @ObservationIgnored let profile: RobotProfile
    /// When the guide's "On target" is felt, in the window the guide draws it with.
    @ObservationIgnored private var onTargetCue: OnTargetCue
    /// A reset's answer came from a server that reports no episode, or a new server run said welcome; the next `state`
    /// from after it arms the on-target cue again.
    @ObservationIgnored private var onTargetRearmOwed = false
    /// Turns the keys, touches, the phone's attitude and the pad's buttons into commands.
    @ObservationIgnored private(set) var controller: OperatingController!
    /// The measured flex in the first state after the last reset, for the tilt window (I-8.3).
    @ObservationIgnored private var flexAtReset: Double?
    @ObservationIgnored private var flexAtResetOwed = true
    @ObservationIgnored private var lastEpisode: Int?
    @ObservationIgnored private var lastWelcomeSession: String?
    /// The newest refusal the operator heard, and when, for the one-second display.
    @ObservationIgnored private var lastRefusal: (refusal: Refusal, atMs: Int)?
    @ObservationIgnored private var lastServerRefusal: (refusalClass: ServerRefusalClass, moveEnded: Bool, atMs: Int)?
    /// The newest ending of a follow or a move nobody held that the operator did not cause, and when, shown as a
    /// refusal is.
    @ObservationIgnored private var lastEnded: (end: DriveEnd, atMs: Int)?
    /// The newest saved take, and when, for the two-second display.
    @ObservationIgnored private var lastSaved: (count: Int, atMs: Int)?
    /// Where the arm hold being started takes its motion from: the phone, a pad button, or a move to a point the
    /// operator tapped. The phone unless a caller says otherwise.
    @ObservationIgnored private var pendingArmSource: ArmSource = .phone
    /// Where the guide's view from above is drawn, in the operating screen's coordinates, which touches arrive in, as
    /// the screen reported it; nil while it is not drawn. Not observed: the screen reports it while laying out.
    @ObservationIgnored private(set) var guidePanelRect: SurfaceLayout.Rect?
    @ObservationIgnored private var guideBehindRect: SurfaceLayout.Rect?
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []

    static let controlModeKey = "controlMode"
    static let handKey = "hand"
    static let taskAidKey = "taskAid"
    static let operatingFixtureKey = "operatingFixture"
    static let assistKey = "assist"
    static let lockChoiceKey = "lockVariant"

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
            recordSettings()
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
            recordSettings()
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
            recordSettings()
            refreshOperating()
        }
    }

    /// Settings → Aids, the master switch, kept across launches. On by default. Off turns every aid off: the operating
    /// screen, its cues and its guide are then version 1.0.1's. Refused, like the mode, while anything is engaged.
    var assistOn: Bool {
        get { assistSetting }
        set {
            guard newValue != assistSetting else { return }
            guard !Self.engaged(session.state), !controller.isEngaged else {
                raise(.refused(.letGoFirst))
                return
            }
            assistSetting = newValue
            UserDefaults.standard.set(newValue, forKey: Self.assistKey)
            // Rounds with and without the aids are compared from the developer log.
            log("assist: \(newValue ? "on" : "off")")
            recordSettings()
            assistDidChange()
        }
    }

    /// Settings → Aids → Lock, kept across launches as its raw value. Off by default. It counts only when the master
    /// switch is on and the robot allows lock. Refused while anything is engaged.
    var lockChoice: LockChoice {
        get { lockChoiceSetting }
        set {
            guard newValue != lockChoiceSetting else { return }
            guard !Self.engaged(session.state), !controller.isEngaged else {
                raise(.refused(.letGoFirst))
                return
            }
            lockChoiceSetting = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.lockChoiceKey)
            log("assist: lock \(newValue.rawValue)")
            recordSettings()
            assistDidChange()
        }
    }

    /// The aids' page in Settings offers lock's choices, each a row under lock's header: the robot allows lock. They
    /// are shown with the master switch off too, disabled, so the choice can be seen and kept.
    var offersLock: Bool { profile.assist.lock != nil }

    /// The one configuration of the aids, resolved from the two settings and the robot. Derived, never stored, so it
    /// cannot disagree with them.
    var assist: Assist {
        var settings = profile.assist
        if !aimViewsAllowed { settings.views = nil }
        return Assist.resolve(masterOn: assistSetting, lockChoice: lockChoiceSetting, profile: settings)
    }

    private func assistDidChange() {
        controller.assistChanged(assist)
        guideAidsChanged()
        link.anyAidOn = assist != .off
        // A cue keeps the window it was made with: a new window takes a new cue, armed as after a scene reset.
        let window = onTargetWindow
        if window != onTargetCue.window { onTargetCue = OnTargetCue(window: window) }
        refreshOperating()
    }

    /// The window "On target" is judged in now, by the guide and its cue alike.
    private var onTargetWindow: SIMD2<Double> { GuidePicture.onTargetWindow(profile, aids: assist.guide) }

    /// Hands the link the guide's aids it runs, with the work box in gripper-link space: the profile keeps the box for
    /// the pinch point, the server keeps the gripper link in it, and the guide draws ring and box moved by the same
    /// measured offset, so judging the commanded gripper-link point against the box less the tool offset is what the
    /// picture shows. A floor below the table is not told while the lowest rule runs: the table stops the arm first,
    /// and that rule tells it. With the lowest rule off the floor is watched like every other face, so a push into the
    /// table is still told.
    private func guideAidsChanged() {
        var sides = Set(OperatorDirection.allCases)
        let floorBelowTable = min(profile.workspaceMin.z, profile.workspaceMax.z) < profile.tableHeight
        if floorBelowTable, assist.guide?.lowestCue == true { sides.remove(.down) }
        link.guideAidsChanged(
            assist.guide, gripperBox: profile.gripperWorkspace, sides: sides,
            directionalBlocked: profile.usesDirectionalBlockedFeedback)
    }

    /// A saved Bool that a launch argument can set as YES or NO. A launch argument arrives as a string, which a cast
    /// to Bool misses, so whether it is there and what it says are read apart.
    static func savedBool(_ key: String, default value: Bool, _ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }

    /// - Parameters:
    ///   - haptics, sounds, speech: nil plays them on the device, except in the unit-test host and under the UI tests'
    ///     `-quietCues YES`, which stay silent.
    ///   - makeObserverTransport: the listening connection's socket; `makeTransport` when nil.
    ///   - clientName: how the app names itself to the server; the bundle's version and build unless a test passes one.
    ///   - profile: the robot; everything that needs one, the link included, uses this one.
    ///   - assistOn, lockChoice: the aids' settings for this model in place of the saved ones, and giving them saves
    ///     nothing; nil reads the saved settings.
    init(
        start: Route = .s2,
        haptics: HapticsPlaying? = nil,
        sounds: SoundPlaying? = nil,
        speech: SpeechPlaying? = nil,
        axisRecognizer: AxisSpeechRecognizing? = nil,
        pose: @escaping () -> simd_float4x4? = { PoseTracker.shared.current },
        liveLink: Bool = AppModel.launchesOnTheRealServer(),
        makeTransport: @escaping (URL) -> LinkTransport = { WebSocketTransport(url: $0) },
        makeObserverTransport: ((URL) -> LinkTransport)? = nil,
        nowMs: @escaping () -> Int = { Int(Date().timeIntervalSince1970 * 1000) },
        inputClock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        clientName: String = LiveLinkController.clientName(),
        profile: RobotProfile = .so101Simulator,
        assistOn: Bool? = nil,
        lockChoice: LockChoice? = nil,
        sessionRecord: SessionRecord = .shared,
        experimentTiming: ExperimentTiming? = nil,
        voiceActionsPrototype: Bool = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[
            "voiceActionsPrototype"
        ] as? String == "YES"
    ) {
        self.profile = profile
        self.sessionRecord = sessionRecord
        self.experimentTiming = experimentTiming ?? ExperimentTiming()
        self.axisRecognizer = axisRecognizer ?? AxisSpeechRecognizer()
        self.voiceActionsPrototype = voiceActionsPrototype
        var state = FakeTeleopState()
        state.liveLink = liveLink
        // Loaded in practice too, so leaving practice connects to it.
        if let saved = UserDefaults.standard.string(forKey: Self.serverAddressKey) {
            state.serverAddress = saved
        }
        session = TeleopSession(state: state, start: start)
        let defaults = UserDefaults.standard
        aimViewsAllowed = Self.savedBool("aimViews", default: true, defaults)
        let mode = defaults.string(forKey: Self.controlModeKey).flatMap(ControlMode.init(rawValue:)) ?? .screenTurns
        let hand: Hand = defaults.string(forKey: Self.handKey) == "left" ? .left : .right
        let taskAid = Self.savedBool(Self.taskAidKey, default: true, defaults)
        let fixture = defaults.string(forKey: Self.operatingFixtureKey).flatMap(OperatingDisplay.fixture(named:))
        modeSetting = mode
        handSetting = hand
        taskAidSetting = taskAid
        let masterOn = assistOn ?? Self.savedBool(Self.assistKey, default: true, defaults)
        let chosenLock =
            lockChoice ?? defaults.string(forKey: Self.lockChoiceKey).flatMap(LockChoice.init(rawValue:)) ?? .off
        assistSetting = masterOn
        lockChoiceSetting = chosenLock
        let resolved = Assist.resolve(masterOn: masterOn, lockChoice: chosenLock, profile: profile.assist)
        onTargetCue = OnTargetCue(window: GuidePicture.onTargetWindow(profile, aids: resolved.guide))
        self.fixture = fixture
        operating =
            fixture
            ?? OperatingDisplay(
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
            gripperLimits: profile.gripperLimits, clientName: clientName
        )
        stopExits = StopExits.offered(recorder: nil, practice: !liveLink)
        self.experimentTiming.send = { [weak self] type, payload in
            _ = self?.link.sendDiagnostic(type: type, payload: payload)
        }
        link.onWireEvent = { [weak self] type, payload, at in
            guard let self else { return }
            if type == "welcome" { timingWelcome = payload }
            guard speechActive else { return }
            self.experimentTiming.receive(type: type, payload: payload, localMonotonicNs: at)
        }
        cues.onDecision = { [weak self] event, at in
            self?.experimentTiming.decision(event: String(describing: event), localMonotonicNs: at)
        }
        cues.onSpeechEvent = { [weak self] stage, id, at in
            self?.experimentTiming.speech(stage: stage, id: id, localMonotonicNs: at)
        }
        sessionRecord.launched()
        recordSettings()
        cues.onSpeechLog = { [weak sessionRecord] in sessionRecord?.note($0) }
        cues.onAudioWillPlay = { [weak self] in self?.suspendVoiceListening() }
        cues.onAudioSettled = { [weak self] in self?.resumeVoiceListening() }
        self.axisRecognizer.onEvent = { [weak self] epoch, event in self?.voiceRecognition(epoch: epoch, event: event) }
        cues.currentHold = { [weak self] in self?.currentHold }
        cues.isReady = { [weak self] in self?.readyToAnnounce == true }
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
        link.onStopSeen = { [weak self] in self?.stopEpoch += 1 }
        link.onWristStartSent = { [weak self] in self?.controller.wristStartSent() }
        link.onSimulatorLevel = { [weak self] in self?.simulatorLevelChanged(from: $0, to: $1) }
        controller = OperatingController(
            model: self, mode: mode, hand: hand, constants: profile.inputConstants, assist: assist, now: inputClock
        )
        guideAidsChanged()
        link.anyAidOn = assist != .off
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
        PoseTracker.shared.onRun = { [weak self] in self?.controller.trackerRan(at: $0) }
        PoseTracker.shared.onRecord = { [weak sessionRecord] in sessionRecord?.note($0) }
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
        voiceResume?.cancel()
        axisRecognizer.stop()
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

    /// The operating screen: where the guide's view from above is drawn, or nil when it is not.
    func guidePanelChanged(_ rect: SurfaceLayout.Rect?) {
        guard rect != guidePanelRect else { return }
        guidePanelRect = rect
    }

    func guideBehindChanged(_ rect: SurfaceLayout.Rect?) {
        guideBehindRect = rect
    }

    /// One raw touch on the operating screen, with `UITouch.timestamp`.
    func touch(_ sample: TouchSample, at time: TimeInterval) {
        recordTouch(sample, at: time)
        controller.touch(sample, at: time)
    }

    func setPrecisionPanelOpen(_ open: Bool) {
        controller.setPrecisionPanelOpen(open)
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

    /// What Connect and Settings say while practice is refused for the latched stop. An owed STOP has reached no robot
    /// yet (J7): the robot is not stopped then, and the way out starts with connecting. Reconnect's unconfirmed stop is
    /// not said to have stopped the robot either: only that it goes out again on connecting.
    var practiceBlockedReason: LocalizedStringKey {
        if stopCause == .reconnect, pressedStop == .owed || pressedStop == .sent {
            return "settings.practice_blocked_unconfirmed"
        }
        return stopOwed ? "settings.practice_blocked_unsent" : "settings.practice_blocked"
    }

    /// Drops the current link and starts the other, so no session spans both.
    private func switchLink(live: Bool) {
        guard live != session.state.liveLink, !session.state.emergencyStop else { return }
        link.closeQuietly()
        session.state.liveLink = live
        if live, session.state.serverAddress.isEmpty,
            let saved = UserDefaults.standard.string(forKey: Self.serverAddressKey)
        {
            session.state.serverAddress = saved
        }
        send(.switchLink)
    }

    var voiceAxisLabel: String {
        if let failure = voiceAxisFailure {
            switch failure {
            case .permission: return L10n.string("voice.error.permission")
            case .unavailable: return L10n.string("voice.error.unavailable")
            case .audio: return L10n.string("voice.error.audio")
            case .interrupted: return L10n.string("voice.error.interrupted")
            case .unsupportedTool: return L10n.string("voice.error.unsupported_tool")
            }
        }
        if let axis = voiceAxisSession.axis {
            switch axis {
            case .height: return L10n.string("voice.axis.height")
            case .foreAft: return L10n.string("voice.axis.fore_aft")
            case .leftRight: return L10n.string("voice.axis.left_right")
            }
        }
        if voiceActionsPrototype {
            return L10n.string(voiceAxisSession.enabled ? "voice.action.listening" : "voice.action.enable")
        }
        return L10n.string(voiceAxisSession.enabled ? "voice.listening" : "voice.enable")
    }

    func toggleVoiceAxis() {
        if voiceAxisSession.enabled { disableVoiceAxis(reason: "operator_disabled"); return }
        guard voiceInputIdle else { raise(.refused(.letGoFirst)); return }
        guard session.state.liveLink, link.toolCalibrationID != nil else {
            voiceAxisFailure = .unsupportedTool
            return
        }
        voiceAxisFailure = nil
        voiceAxisSession.enable()
        voiceRecord("enabled")
        resumeVoiceListening()
    }

    func disableVoiceAxis(reason: String) {
        if voiceMotion != nil { finishVoiceMotion(reason: reason) }
        guard voiceAxisSession.enabled else { return }
        voiceAxisSession.disable()
        voiceResume?.cancel()
        voiceResume = nil
        axisRecognizer.stop()
        cues.cancelVoiceAxisConfirmation()
        controller?.selectTranslationAxis(nil)
        voiceRecord("disabled", ["reason": reason])
    }

    private var voiceInputIdle: Bool {
        guard let controller else { return false }
        return voiceMotion == nil && !controller.isEngaged && !controller.arbiter.isHoldingAnInput
            && controller.buttons.down.isEmpty
            && !controller.precisionPanelOpen && !session.state.armMoving && !session.state.wristMoving
            && session.state.gripperMoving == nil
    }

    private var voiceMayListen: Bool {
        speechActive && voiceInputIdle && !cues.hasAudio && modeSetting != .buttons
            && OperatingController.operatingRoutes.contains(session.route)
            && session.state.connected && !session.state.emergencyStop && !session.state.commandsBlocked
            && !link.resetPending && serverState?.simBusy != true && link.toolCalibrationID != nil
    }

    private func suspendVoiceListening() {
        guard voiceAxisSession.enabled else { return }
        voiceResume?.cancel()
        voiceResume = nil
        if voiceAxisSession.listeningEpoch != nil {
            voiceAxisSession.suspend()
            axisRecognizer.stop()
            voiceRecord("capture_suspended")
        }
    }

    private func resumeVoiceListening() {
        guard voiceAxisSession.enabled, voiceAxisSession.listeningEpoch == nil,
            voiceResume == nil, voiceMayListen
        else { return }
        let resume = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.voiceResume = nil
            guard self.voiceMayListen, let epoch = self.voiceAxisSession.beginListening() else { return }
            self.voiceRecord("capture_requested", ["epoch": epoch])
            self.axisRecognizer.start(epoch: epoch, language: SpeechText.voiceLanguage())
        }
        voiceResume = resume
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: resume)
    }

    private func voiceRecognition(epoch: Int, event: AxisSpeechEvent) {
        guard voiceAxisSession.listeningEpoch == epoch else { return }
        switch event {
        case .listening:
            voiceRecord("capture_started", ["epoch": epoch])
        case .transcript(let text, let final, let captured):
            let now = controller.now()
            let inputIdle = voiceInputIdle
            if voiceActionsPrototype, voiceMayListen, !stopOwed,
                let action = voiceAxisSession.acceptAction(
                    text, final: final, epoch: epoch, capturedAt: captured, now: now, inputIdle: inputIdle)
            {
                disableVoiceAxis(reason: "action_consumed")
                startVoiceMotion(action)
                return
            }
            guard
                let axis = voiceAxisSession.accept(
                    text, final: final, epoch: epoch, capturedAt: captured, now: now, inputIdle: inputIdle)
            else {
                if final {
                    let age = now - captured
                    voiceRecord(
                        "selection_rejected",
                        [
                            "epoch": epoch,
                            "input_idle": inputIdle,
                            "phrase_matched": TranslationAxis.recognized(text) != nil,
                            "capture_age_s": age.isFinite ? String(format: "%.3f", age) : "invalid",
                        ])
                }
                return
            }
            axisRecognizer.stop()
            controller.selectTranslationAxis(axis)
            voiceRecord("axis_selected", ["axis": axis.rawValue, "epoch": epoch, "capture_uptime_s": captured])
            raise(.voiceAxis(axis))
            resumeVoiceListening()
        case .ended:
            voiceAxisSession.suspend()
            voiceRecord("capture_ended", ["epoch": epoch])
            resumeVoiceListening()
        case .failed(let failure):
            disableVoiceAxis(reason: "recognition_" + failure.rawValue)
            voiceAxisFailure = failure
        }
    }

    private func voiceRecord(_ kind: String, _ details: [String: Any] = [:]) {
        sessionRecord.note(
            "voice " + kind + " " + details.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))
        experimentTiming.event(kind: "voice." + kind, details: details)
        onVoiceEvent?(kind, details)
    }

    // MARK: Raw inputs from the device

    /// A volume key's capture event: `down` for began, false for ended or cancelled.
    func keyEvent(_ key: InputKey, down: Bool) {
        experimentTiming.event(kind: "key_edge", details: ["key": String(describing: key), "down": down])
        if down { suspendVoiceListening() }
        controller.key(key, down: down)
        if !down { resumeVoiceListening() }
    }

    /// An ARKit frame: the camera's transform while tracking is normal, nil otherwise, and the frame's timestamp. Any
    /// frame, tracked or not, can show that the camera runs again after the app ran it.
    func poseFrame(_ camera: simd_float4x4?, at time: TimeInterval) {
        controller.cameraFrame(stampedAt: time)
        cues.refreshReadiness()
        guard let camera else { disableVoiceAxis(reason: "tracking_lost"); return }
        controller.attitude(PhoneAttitude.portrait(cameraTransform: camera), at: time)
    }

    /// The app became active or left the active state (a call, the home screen, Control Center). Every hold ends, with
    /// its stop, on leaving; inputs held across it stay dead; the link's old latency probes are dropped.
    func activeChanged(_ active: Bool) {
        speechActive = active
        cues.refreshReadiness()
        if !active { recordedTouches.removeAll() }
        controller.activeChanged(active)
        link.foregroundChanged(active)
        if !active {
            experimentTiming.event(kind: "app_suspended", details: [:])
            experimentTiming.reset()
        } else if link.isUp, let timingWelcome {
            experimentTiming.receive(
                type: "welcome", payload: timingWelcome,
                localMonotonicNs: DispatchTime.now().uptimeNanoseconds)
        }
    }

    func measurementTick() {
        experimentTiming.tick()
        if let voiceMotion, nowMs() >= voiceMotion.deadline {
            finishVoiceMotion(reason: "timeout")
            raise(.letGo(.noAnswer))
        }
    }

    private func startVoiceMotion(_ action: VoiceAction) {
        guard let startStamp = link.voiceMotionStartStamp else {
            voiceRecord("action_refused", ["reason": "no_fresh_idle_state"])
            raise(.refused(.notReady))
            return
        }
        let goal: VoiceGoal
        let timeout: Int
        switch action {
        case .forward, .up:
            guard let start = link.freshToolPointForStep else {
                voiceRecord("action_refused", ["reason": "tool_state_unavailable"])
                raise(.refused(.notReady))
                return
            }
            let direction: OperatorDirection = action == .forward ? .forward : .up
            let offset = direction.linkVector * 0.005
            goal = .step(offset: offset, target: start + OperatorFrame.base(fromLink: offset))
            timeout = 2_000
        case .open, .close:
            goal = .gripper(action == .open ? .open : .closed)
            timeout = 7_000
        }
        voiceMotion = VoiceMotion(action: action, goal: goal, deadline: nowMs() + timeout, startStamp: startStamp)
        voiceRecord("action_requested", ["action": action.rawValue])
        switch goal {
        case .step:
            startArmHold(.pad)
            if !session.state.armMoving { finishVoiceMotion(reason: "start_refused", sendEnd: false) }
        case .gripper(let target):
            send(.gripperStart(target))
            if session.state.gripperMoving != target { finishVoiceMotion(reason: "start_refused", sendEnd: false) }
        }
    }

    private func finishVoiceMotion(reason: String, sendEnd: Bool = true) {
        guard let motion = voiceMotion else { return }
        voiceMotion = nil
        voiceRecord("action_ended", ["action": motion.action.rawValue, "reason": reason])
        guard sendEnd else { return }
        switch motion.goal {
        case .step: send(.holdArmEnd)
        case .gripper: send(.gripperEnd)
        }
    }

    private func observeVoiceMotion(_ state: ServerState) {
        guard let motion = voiceMotion, !state.estop,
            let stamp = link.latestVoiceMotionStateStamp, stamp > motion.startStamp
        else { return }
        switch motion.goal {
        case .step(_, let target):
            if state.activity == .poseTracking, let point = state.toolPoint,
                simd_distance(point, target) <= 0.001
            {
                finishVoiceMotion(reason: "target_reached")
            }
        case .gripper(let target):
            if target == .closed, state.activity == .gripperContact {
                finishVoiceMotion(reason: "contact")
            } else if state.activity == .gripperJogging, let angle = state.gripperDeg,
                target == .open ? angle >= profile.gripperLimits.openDeg : angle <= profile.gripperLimits.emptyDeg
            {
                finishVoiceMotion(reason: "gripper_limit")
            }
        }
    }

    // MARK: What the input rules are told

    /// The facts of this moment for the input rules (§2.3 I-5, A-2g, I-8.3).
    func inputFacts() -> InputFacts {
        let s = session.state
        let settingsOpen = session.route == .s6
        let notReady = s.liveLink && (link.resetPending || serverState?.simBusy == true)
        var refusal: InputRefusal?
        if robotStopped(s) {
            refusal = .stopped
        } else if !s.connected || stopOwed {
            refusal = .noLink
        } else if settingsOpen {
            refusal = .settingsOpen
        } else if s.commandsBlocked {
            refusal = .slowLink
        } else if notReady {
            refusal = .wait
        } else if voiceAxisSession.enabled, voiceAxisSession.axis == nil {
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
        var facts = InputFacts(
            refusal: refusal,
            trackingRefusal: controller.isCameraStopped || camera == nil ? .notTracking : nil,
            translationRefusal: PhonePosture.of(camera) == .tilted ? .posture : nil,
            resetRefusal: resetRefusal,
            gripping: profile.recloseLoosensGrip && gripping,
            wrist: WristReadings(
                rollDeg: serverState?.wristRollDeg, flexDeg: serverState?.wristFlexDeg, flexAtResetDeg: flexAtReset
            ),
            connectionUp: !s.liveLink || link.isUp || link.observerUp,
            attitudeFrame: controller.attitudeFrame
        )
        // Tap-to-go starts from where the arm was measured and judges a tap against the panel drawn; without it the
        // facts are version 1.0.1's. While the camera is stopped no key reaches the app and the screen says so, so a
        // move started then could not be seen or stopped with a key: the rules get no panel, and a touch on the guide
        // is what it was without tap-to-go.
        if assist.goTo != nil {
            facts.arm = armFix
            if !controller.isCameraStopped { facts.goPanel = goPanel }
        }
        return facts
    }

    /// The panel the input rules judge a tap against: where the screen reported the guide's view from above, with the
    /// projection, the work box and the table of the picture drawn there. Nil unless the guide is drawn: a phone mode,
    /// the task aid on, an arm reading, and the view reported.
    private var goPanel: GoPanel? {
        guard operating.mode != .buttons, operating.taskAid, let picture = operating.guide, let rect = guidePanelRect
        else { return nil }
        return GoPanel(
            rect: rect, projection: picture.projection, boxLow: picture.workBoxLow, boxHigh: picture.workBoxHigh,
            tableHeight: Double(profile.tableHeight), behind: assist.views == nil ? nil : guideBehindRect)
    }

    /// Where the arm was last measured, for tap-to-go: the pinch point of the newest position either connection
    /// reported, how old it is, whether the link is pausing the hold, whether a position from after the server
    /// finished the last hold this phone ended has been heard, and the gripper link of the same position with whether
    /// the server reported the pinch point there, so that a move can follow how the pinch point turns about the
    /// gripper link. Nil before the server has reported one.
    private var armFix: ArmFix? {
        guard let state = link.newestArmState, let gripper = state.endEffector, let ageMs = link.newestArmAgeMs else {
            return nil
        }
        let pinch = profile.pinchPoint(
            gripper: SIMD3<Float>(gripper), tool: state.toolPoint.map { SIMD3<Float>($0) },
            flexDeg: state.wristFlexDeg, rollDeg: state.wristRollDeg)
        return ArmFix(
            pinch: SIMD3<Double>(pinch.point), ageS: Double(ageMs) / 1000, holdPaused: link.holdPaused,
            heardAfterLastStop: link.armHeardAfterLastStop, gripper: gripper, pinchReported: pinch.source == .reported)
    }

    /// The controller handled an input; what the screen draws may have changed.
    func inputsChanged() {
        refreshOperating()
        resumeVoiceListening()
    }

    /// Starts the session's arm hold with its motion from `source`. `send(.holdArmStart)` alone starts a phone hold,
    /// as in version 1.0.1.
    func startArmHold(_ source: ArmSource) {
        pendingArmSource = source
        send(.holdArmStart)
        pendingArmSource = .phone
    }

    /// Buttons mode: a direction button's hold. The link streams the pad's ramp instead of the phone's movement.
    func startButtonTranslation() {
        startArmHold(.pad)
    }

    /// The input rules latched the arm hold: it goes on with no input held. Marks the link's hold as one nobody holds,
    /// so the endings the link causes are told as the follow's own, and plays the latch cue. False, and silent, when
    /// the session runs no arm hold: the start the latch came with was refused, and that refusal is what the operator
    /// heard.
    func armHoldBecameLoose() -> Bool {
        guard session.state.armMoving else { return false }
        if session.state.liveLink { link.holdIsLoose = true }
        raise(.drive(.latched))
        return true
    }

    /// Counts every stop that began: each STOP press, and each stop the server began on either connection, also
    /// while the stop is already latched here. A reset counted down from before a stop must not clear it.
    private(set) var stopEpoch = 0
    /// `stopEpoch` when a reset was asked for from the stop: its confirmation releases the stop only if no stop
    /// began since.
    private var resetFromStopEpoch: Int?

    /// The top band was held 2 s (§6.4): reset the scene. In the stop state the server's reset clears the stop
    /// once it confirms it (`sceneResetDone`), unless STOP is pressed again first; the practice link resets at once.
    /// `stopEpochAtStart` is `stopEpoch` when the countdown began: a stop since then makes this reset not go out.
    func runReset(stopEpochAtStart: Int? = nil) {
        if let start = stopEpochAtStart, start != stopEpoch {
            log("→ reset dropped: a stop began during its countdown")
            raise(.notReset)
            return
        }
        let s = session.state
        // A stopped simulator could never run the reset, and a server may clear its stop for one.
        if s.liveLink, link.simulatorStalled {
            log("→ reset refused: the simulator is not responding")
            raise(.refused(.simulatorStalled))
            return
        }
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
                resetFromStopEpoch = stopEpoch
                perform(.resetScene, fromServer: false)
            } else {
                raise(.notReset)
            }
        } else {
            send(.resetScene)
        }
    }

    func send(_ action: TeleopAction) {
        if controller?.precisionPanelOpen == true {
            let allowed: Bool
            switch action {
            case .holdArmStart:
                allowed = pendingArmSource == .pad && controller.buttons.engaged?.direction != nil
            case .gripperStart(let target):
                allowed = controller.buttons.engaged == (target == .open ? .open : .close)
            case .wristStart:
                allowed = false
            default:
                allowed = true
            }
            if !allowed {
                raise(.refused(.letGoFirst))
                return
            }
        }
        if case .gripperStart = action, session.state.gripperMoving != nil, case .gripper? = voiceMotion?.goal {
            finishVoiceMotion(reason: "manual_override", sendEnd: false)
        }
        if action == .stop { stopEpoch += 1 }
        // A reset is refused while anything is held: the operator lets go first.
        if action == .resetScene, Self.engaged(session.state) {
            log("→ \(action) refused: something is held")
            raise(.refused(.letGoFirst))
            return
        }
        // With the simulator not responding the server could never release its stop, or would release one nothing
        // holds: the stop stays latched here, and the press is felt, not spoken, since the screen already says why.
        if action == .releaseStop, session.state.liveLink, link.simulatorStalled {
            log("→ \(action) refused: the simulator is not responding")
            raise(.refused(.simulatorStalled))
            return
        }
        // Reconnect's owed stop may have reached the server unconfirmed: releasing it here would leave that server
        // stopped by nothing the phone still holds, and the stop would never be sent again. It is released once a
        // server has it. A STOP pressed with no link reached no server, so it may still be released here.
        if action == .releaseStop, session.state.emergencyStop, stopOwed, stopCause == .reconnect {
            log("→ \(action) refused: no server has confirmed Reconnect's stop")
            raise(.refused(.noLink))
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
        if case .ready = event, session.state.liveLink, link.isUp, !session.state.connected, session.route == .s1 {
            readyAfterWelcome = true
            return
        }
        cues.raise(event)
        switch event {
        case .refused(let refusal): lastRefusal = (refusal, nowMs())
        // A server's refusal of a start is shown as a refusal is, and its ending of a move nobody holds as that move's
        // ending; its ending of a hold someone holds, as a let-go, is not.
        case .serverRefusal(let refusalClass, accepted: false): lastServerRefusal = (refusalClass, false, nowMs())
        case .drive(.endedByServer(let refusalClass)): lastServerRefusal = (refusalClass, true, nowMs())
        // The operator's own ending and an arrival are not shown: the operator knows why.
        case .drive(.ended(let end)): lastEnded = (end, nowMs())
        case .takeSaved(let count): lastSaved = (count, nowMs())
        default: return
        }
        refreshOperating()
    }

    /// The cues decided so far, newest last.
    var cueLog: [CueLogEntry] { cues.log }

    /// The simulator paused, stopped responding or runs again. A pause is only shown; not responding is said once, and
    /// so is the simulator coming back from it.
    private func simulatorLevelChanged(from before: SimStallDetector.Level, to after: SimStallDetector.Level) {
        if after == .notResponding {
            // The server's own newest state counts too: a stop it reports latches here a moment later.
            let stopped = (session.state.emergencyStop && !stopOwed) || link.serverSaysStopped
            raise(stopped ? .simulatorStalled : .simulatorStalledUnstopped)
        }
        if after == .running {
            if before == .notResponding { raise(.simulatorBack) }
            if let automatic = stopLatchedWhilePaused, session.state.emergencyStop {
                raise(
                    automatic
                        ? .simulatorAutoStopped
                        : .emergencyStop(.other, takeDiscarded: session.state.liveLink && narrator.stopDiscardsTake))
            }
            stopLatchedWhilePaused = nil
        }
        refreshOperating()
    }

    /// **Reconnect** while the simulator is not responding leaves the server stopped: a stop not latched yet is pressed
    /// here as STOP is, so it is recorded as sent, then confirmed, or owed when its connection closes first, and it goes
    /// out again after the next welcome. Only the cause differs: no alarm and no "you pressed stop".
    /// True when it sent an `estop`.
    @discardableResult
    func stopBeforeReconnect() -> Bool {
        guard session.state.liveLink, link.isOpen, !session.state.emergencyStop else { return false }
        log("link: Reconnect latches the stop and sends it before disconnecting")
        reconnectPressingStop = true
        defer { reconnectPressingStop = false }
        send(.stop)
        return true
    }

    /// **Reconnect**: the server is left stopped before the connection goes, then Connect opens. A stop sent now keeps
    /// the connection until the server confirms it, for at most `LiveLinkController.reconnectStopWaitMs`: closing at
    /// once could cancel the `estop` before it leaves. Closed before it was confirmed, by the wait's end or any other
    /// way, the stop is owed as any pressed STOP is.
    func reconnect() {
        guard !link.waitingToCloseAfterStop else { return }
        guard stopBeforeReconnect() else {
            leaveForConnect()
            return
        }
        link.whenStopConfirmed { [weak self] confirmed in
            guard let self else { return }
            if !confirmed { log("link: Reconnect's stop was not confirmed; it is sent again after the next welcome") }
            leaveForConnect()
        }
    }

    private func leaveForConnect() {
        send(.disconnect)
        send(.changeServer)
    }

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
        if action == .linkLost {
            experimentTiming.reset()
            timingWelcome = nil
        }
        if action == .stop, session.state.emergencyStop { return }
        if action == .sceneResetDone {
            // A stop that began after the reset was asked for is one the reset never meant to clear.
            if let asked = resetFromStopEpoch, asked != stopEpoch { session.state.resetClearsStop = false }
            resetFromStopEpoch = nil
        }
        if action == .linkLost, session.state.connected {
            let engaged = Self.engaged(session.state)
            holdEngagedAtLoss = engaged
            narrator.linkLost()
            raise(.linkLost(holdEngaged: engaged))
        }
        perform(action, fromServer: true)
        if case .linkUp = action, readyAfterWelcome {
            readyAfterWelcome = false
            if readyToAnnounce { raise(.ready) }
        }
    }

    /// A `state` from either connection.
    private func stateArrived(_ state: ServerState) {
        if serverState != state { serverState = state }
        observeVoiceMotion(state)
        // Only a state the server wrote after reading this STOP's `estop` confirms it, never one from before the press.
        // Once a reset has been asked for from the stop, which clears the server's stop even when refused, none does:
        // only a new STOP can be confirmed again.
        if pressedStop == .sent, link.estopConfirmed, !session.state.resetClearsStop { pressedStop = .confirmed }
        // The on-target cue is armed again on a state from after a reset, never on the reset's answer: until then the
        // guide still shows the arm from before the reset, and so may a state the server sent while still resetting.
        if onTargetRearmOwed, state.activity != .resetting {
            onTargetRearmOwed = false
            onTargetCue.rearm()
        }
        if let episode = state.episode {
            if let last = lastEpisode, episode != last {
                sceneWasReset()
                onTargetCue.rearm()
            }
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
        experimentTiming.event(
            kind: "state_model_commit",
            details: [
                "presentation": "not_measured", "source_binding": "unavailable_typed_state_has_no_source_id",
            ])
    }

    /// The control connection's welcome. With the stop latched, `estop` goes out first, whatever latched it: the server
    /// may have restarted and forgotten it, and one still stopped loses nothing by hearing it again. Only a STOP that
    /// reached no server before is announced, with the alarm.
    private func welcomed(session run: String?) {
        narrator.welcomed(session: run)
        // A new server run starts from its own reset pose. A server that names no run cannot tell a reconnect from a
        // new run, so the tilt window keeps counting from the last reset seen (I-8.3).
        if let run, run != lastWelcomeSession {
            lastWelcomeSession = run
            lastEpisode = nil
            sceneWasReset()
            onTargetRearmOwed = true
        }
        guard session.state.emergencyStop else { return }
        link.estop()
        let owed = stopOwed
        // This server has not confirmed a STOP pressed here yet.
        if pressedStop != nil { pressedStop = .sent }
        // Reconnect's stop was never announced: the operator pressed Reconnect, not STOP.
        guard owed, stopCause != .reconnect else {
            log("link: the stop is latched, so estop is sent again")
            if owed { refreshOperating() }
            return
        }
        narrator.emergencyStopLearned()
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
        cues.refreshReadiness()
        guard fixture == nil, let controller else { return }
        let s = session.state
        let arm =
            s.liveLink
            ? OperatingRules.arm(
                serverState, commanded: link.commandedArm, gripping: gripping, profile: profile,
                goTarget: controller.goTarget.map { SIMD3<Float>($0) },
                commandOutside: link.commandOutside, lowestGripperZ: link.lowestSeen.map { Float($0) },
                lowestPinchZ: link.lowestPinchSeen.map { Float($0) }) : nil
        // The guide's aids in force draw into the one picture; nil draws version 1.0.1's.
        let aids = assist
        let display = OperatingDisplay(
            mode: modeSetting, hand: handSetting, state: OperatingRules.state(operatingFacts), layout: surfaceLayout,
            engaged: controller.engagedHold ?? Self.heldControl(s).map(Self.holdKind),
            resetCountdown: controller.resetCountdown, heldButton: controller.buttons.engaged,
            speed: controller.buttons.speed, recorder: recorder, stopExits: stopExits, linkUp: s.connected,
            latencyMs: s.latencyMs, address: s.serverAddress, arm: arm, practice: !s.liveLink, taskAid: taskAidSetting,
            guide: arm.map { GuidePicture(reading: $0, profile: profile, aids: aids.guide, views: aids.views) },
            aidsOff: s.liveLink && !assistSetting && profile.assist != .none,
            precisionPanelOpen: controller.precisionPanelOpen
        )
        if operating.state != display.state {
            let summary = display.state.recordSummary
            if operating.state.recordSummary != summary { sessionRecord.note("screen \(summary)") }
        }
        if operating != display { operating = display }
        feelOnTarget(display)
    }

    /// Plays ON TARGET once as the guide's "On target" turns true with the jaws open, during a hold or after one.
    private func feelOnTarget(_ display: OperatingDisplay) {
        // Only with the server connected: practice draws no arm, and a closed link leaves its last state behind, which
        // must not count as a target reported anew when the link or the real server comes back.
        guard session.state.liveLink, session.state.connected else { return }
        // The picture the screen draws: the cue judges by what is shown, never by a second picture of its own.
        let picture = display.guide
        // A stop the server reports counts before the session has latched it: the same state may bring both.
        let stopped = session.state.emergencyStop || serverState?.estop == true
        let look = OnTargetCue.Look(
            gap: picture?.targetGap, target: display.arm?.target.map(GuidePicture.operatorPoint),
            approximate: picture?.approximate ?? false, holding: picture?.holding ?? false, taskAid: display.taskAid,
            jawsOpen: serverState?.gripper.map { $0 == .open }, stopped: stopped
        )
        if onTargetCue.observe(look, at: nowMs()) { raise(.onTarget) }
    }

    private var readyToAnnounce: Bool {
        guard speechActive, controller != nil, OperatingController.operatingRoutes.contains(session.route) else {
            return false
        }
        let facts = operatingFacts
        let needsCamera = session.state.liveLink && modeSetting != .buttons && !controller.precisionPanelOpen
        let connected = session.state.liveLink ? link.isUp : facts.connected
        return connected && !facts.emergencyStop && !facts.stopOwed && !facts.cameraStopped && !facts.simulatorStalled
            && !facts.simulatorPaused
            && !facts.commandsBlocked && facts.engaged == nil && !facts.serverSaving && !facts.serverResetting
            && (!session.state.liveLink || (serverState?.estop != true && serverState?.simBusy != true))
            && (!needsCamera || pose() != nil)
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
        // Reconnect's stop names no cause: none of the causes the screen knows is what happened.
        facts.stopCause = s.emergencyStop && stopCause != .reconnect ? emergencyCause : nil
        facts.simulatorPaused = s.liveLink && link.simulatorLevel == .paused
        facts.simulatorStalled = s.liveLink && link.simulatorLevel == .notResponding
        // Buttons mode pauses the tracking on purpose, so no frame can come there to show the camera runs. The pad
        // needs no camera, and the screen does not say it stopped.
        facts.cameraStopped = controller.isCameraStopped && modeSetting != .buttons && !controller.precisionPanelOpen
        facts.commandsBlocked = s.commandsBlocked
        facts.latencyMs = s.latencyMs
        facts.engaged = controller.engagedHold ?? Self.heldControl(s).map(Self.holdKind)
        facts.loose = controller.loose
        facts.wristTarget = controller.wristTarget
        facts.wristMeasured = serverState?.wristRollDeg != nil
        facts.catchingUp = catchingUp
        facts.gripping = gripping
        if s.liveLink {
            facts.serverSaving = serverState?.taskSuccess == true || serverState?.activity == .taskSuccess
            facts.serverResetting = link.resetPending || serverState?.activity == .resetting
        }
        facts.lastRefusal = lastRefusal
        facts.lastServerRefusal = lastServerRefusal
        facts.lastEnded = lastEnded
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

    /// The stop is latched and, as far as the app knows, the robot is stopped. An owed STOP has reached no robot yet
    /// (J7), so a refused press then says "No link." and the screen shows the link's state, also while Connect
    /// replaces a link that is up and the session still reads connected.
    private func robotStopped(_ state: FakeTeleopState) -> Bool {
        state.emergencyStop && !stopOwed
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
        let before = session.state
        let routeBefore = session.route
        let wasMoving = before.armMoving
        let heldOnTheLink = Self.isLatency(action) && Self.heldControl(before) != nil && controller.loose == nil
        // A server that counts episodes says every reset with a new episode, which arms the cue once (`stateArrived`).
        if action == .sceneResetDone, lastEpisode == nil { onTargetRearmOwed = true }
        session.perform(action)
        if case .linkLatency(let ms) = action, before.connected, before.liveLink {
            recentRoundTrips.append(ms)
            if recentRoundTrips.count > 8 { recentRoundTrips.removeFirst() }
        }
        if before.commandsBlocked != session.state.commandsBlocked {
            let state = session.state.commandsBlocked ? "on" : "off"
            let sample = recentRoundTrips
            recentRoundTrips.removeAll(keepingCapacity: true)
            sessionRecord.noteLater { "slow link \(state) rtt_ms=\(sample)" }
        } else if before.connected && !session.state.connected {
            recentRoundTrips.removeAll(keepingCapacity: true)
        }
        if routeBefore != .p4, session.route == .p4 {
            UserDefaults.standard.set(true, forKey: Self.firstRunDoneKey)
        }
        if session.state.liveLink { driveLink(action, before: before, fromServer: fromServer) }
        if !session.state.emergencyStop {
            pressedStop = nil
        } else if pressedStop == .sent, !session.state.connected, !link.isOpen {
            // The connection went before the server confirmed the STOP: it is owed, as if pressed with no link, and the
            // operator, who heard the alarm, hears that it has reached no robot. Reconnect's stop played no alarm and
            // may have reached the server: nothing is said, and Connect says it goes out again on connecting.
            pressedStop = .owed
            if stopCause != .reconnect { raise(.refused(.notStopped)) }
        }
        if !before.emergencyStop, session.state.emergencyStop {
            stopCause =
                fromServer ? (pendingServerCause ?? .server("unknown")) : reconnectPressingStop ? .reconnect : .button
        } else if !session.state.emergencyStop {
            stopCause = nil
            stopLatchedWhilePaused = nil
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
            if robotStopped(before) {
                raise(.refused(.emergencyStop))
            } else if !before.connected || stopOwed {
                raise(.refused(.noLink))
            }
        }
        if !session.state.liveLink, let held = Self.heldControl(session.state), held != Self.heldControl(before) {
            // The demo has no server to accept the hold: it is live at once.
            demoHold += 1
            raise(.holdLive(hold: demoHold))
        }
        refreshRecorder()
        // A start the session ignored, or the link could not start, was refused: the operator has heard why. A hold the
        // link ended comes with how the link told the operator, when the hold was one nobody held.
        let told: Interruption? =
            action == .holdArmStart && !session.state.armMoving
            ? .startRefused : action == .holdArmEnd && fromServer ? link.takeLooseEnding() : nil
        if heldOnTheLink, !before.commandsBlocked, session.state.commandsBlocked,
            Self.heldControl(session.state) == nil, assist.explain?.slowLinkLetGo == true
        {
            raise(.letGo(.slowLink))
        }
        controller.sessionChanged(told: told)
    }

    /// The session asks for its own haptic commands; the operator feels and hears the events they stand for.
    private func feedback(for command: HapticCommand, before: FakeTeleopState) {
        switch command {
        case .play(.emergencyLoop):
            guard !stopOwed else {
                raise(.refused(.notStopped))
                return
            }
            narrator.emergencyStopLearned()
            // Reconnect latched it on the way to Connect: the operator pressed Reconnect, not STOP.
            if stopCause == .reconnect {
                log("link: the stop is latched for Reconnect, without the alarm")
                return
            }
            // A stop the server reports while the simulator is paused or not responding is one its loop never ran: it
            // latches without the alarm, and the screen says why. A STOP pressed here is still heard.
            if session.state.liveLink, link.simulatorStalled, stopCause != .button {
                log("link: the stop is kept, not announced again: the simulator is \(link.simulatorLevel)")
                // The server's own stop, not the phone's refused release latching again.
                if case .server(let reason) = stopCause, reason != LiveLinkController.releaseRefusedStallReason {
                    stopLatchedWhilePaused = reason == TeleopLink.simulatorStalledReason
                }
                return
            }
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
        // Never told: Reconnect's stop plays no alarm and the screen names no cause for it.
        case .reconnect: return .other
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
        if action == .stop, !fromServer {
            let reached = link.estop()
            // The press that latches the stop starts a pressed STOP. One pressed while it is latched changes nothing,
            // unless a reset asked for from the stop may have cleared the server's stop: then it waits to be confirmed,
            // and as it plays no alarm of its own, the operator hears here if it reached no server.
            if !before.emergencyStop || before.resetClearsStop {
                pressedStop = reached ? .sent : .owed
                if before.emergencyStop, !reached { raise(.refused(.notStopped)) }
            }
        }
        // The server clears its stop as soon as it reads a reset asked for from the stop, even one it then refuses: a
        // confirmed STOP counts as only sent again, and is owed if the link goes before the reset releases the stop.
        if action == .resetScene, after.resetClearsStop, pressedStop == .confirmed { pressedStop = .sent }
        if before.armMoving, !after.armMoving {
            link.endHold()
            if case .step? = voiceMotion?.goal { finishVoiceMotion(reason: "interrupted", sendEnd: false) }
        }
        // Release, keep scene. A reset that cleared the stop needs no estop_reset.
        if before.emergencyStop, !after.emergencyStop, action == .releaseStop { link.estopReset() }
        if !before.armMoving, after.armMoving {
            switch pendingArmSource {
            case .pad:
                if case .step(let offset, _)? = voiceMotion?.goal {
                    if !link.startButtonHold(useToolPoint: true, { offset }) { buttonHoldNotStarted() }
                } else if !link.startButtonHold(
                    useToolPoint: link.toolCalibrationID != nil,
                    toolMotion: link.supportsCoordinatedHeight
                        && (controller.buttons.engaged == .up || controller.buttons.engaged == .down)
                        ? .coordinatedHeight : nil,
                    { [weak self] in self?.controller.buttonTarget() })
                {
                    buttonHoldNotStarted()
                }
            case .going:
                // A move to a point the operator tapped: a hold on the pad's path, with the input rules' offsets.
                // Nobody holds it, so the link tells the endings it causes as the move's own; nobody steers it, so the
                // link leaves a limit it meets to that ending.
                if link.startButtonHold({ [weak self] in self?.controller.goOffset() }) {
                    link.holdIsLoose = true
                    link.holdIsGoing = true
                } else {
                    buttonHoldNotStarted()
                }
            case .phone:
                let axis = controller.arbiter.translationAxis
                let params = PoseParams(
                    gain: axis == nil ? after.sensitivity : 0.2, smoothing: axis == nil ? after.smoothing : 0,
                    // A free move follows the hand, which turns and curves; the tool-point path holds each server
                    // hold to one straight line and a fixed wrist, so it is asked for only when one axis is chosen.
                    toolCalibrationID: axis == nil ? nil : link.toolCalibrationID,
                    toolMotion: axis == .height && link.supportsCoordinatedHeight ? .coordinatedHeight : nil)
                let held = PhonePosture.of(pose())
                if held == .tilted || !link.startHold(params, axis: axis) {
                    let why = held == .tilted ? "phone held wrong" : "no tracking, no link or a reset"
                    log("link: hold not started (\(why))")
                    if held == .tilted {
                        pendingRefusal = .posture
                    } else if held == .unknown {
                        pendingRefusal = .notTracking
                    } else {
                        pendingRefusal = link.manualTranslationStartRefusal ?? .busy
                    }
                    session.perform(.holdArmEnd)
                    session.pendingCue(.commandBlocked)
                }
            }
        }
        if before.wristMoving != after.wristMoving {
            if after.wristMoving {
                if !link.startWristHold() {
                    log("link: wrist hold not started (no link or a reset)")
                    pendingRefusal =
                        link.simulatorStalled ? .simulatorStalled : link.resetPending ? .notReady : .noLink
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
                if !link.startGripper(target) {
                    if link.simulatorStalled {
                        raise(.refused(.simulatorStalled))
                    } else if link.resetPending {
                        raise(.refused(.notReady))
                    }
                }
            } else {
                link.stopGripper()
                if case .gripper? = voiceMotion?.goal { finishVoiceMotion(reason: "interrupted", sendEnd: false) }
            }
        }
        switch action {
        case .resetScene where before.connected && !before.emergencyStop:
            link.resetScene()
        case .disconnect:
            experimentTiming.reset()
            timingWelcome = nil
            link.closeQuietly()
            holdEngagedAtLoss = false
        case .switchLink:
            experimentTiming.reset()
            timingWelcome = nil
            link.closeQuietly()
            holdEngagedAtLoss = false
            trySavedServer()
        default:
            break
        }
    }

    /// A hold on the pad's path the link could not start: the session drops it, and the operator hears why.
    private func buttonHoldNotStarted() {
        let reason = link.manualTranslationStartRefusal ?? .busy
        log("link: button hold not started reason=\(reason.rawValue)")
        pendingRefusal = reason
        session.perform(.holdArmEnd)
        session.pendingCue(.commandBlocked)
    }

    private static func isLatency(_ action: TeleopAction) -> Bool {
        if case .linkLatency = action { return true }
        return false
    }

    private func recordSettings() {
        let mode = modeSetting.rawValue
        let hand = handSetting == .left ? "left" : "right"
        let taskAid = taskAidSetting
        let assist = assistSetting
        let lock = lockChoiceSetting.rawValue
        let language = language.rawValue
        sessionRecord.noteLater {
            "settings mode=\(mode) hand=\(hand) taskAid=\(taskAid) assist=\(assist) lock=\(lock) language=\(language)"
        }
    }

    private func recordTouch(_ sample: TouchSample, at time: TimeInterval) {
        guard sessionRecord.url != nil else { return }
        if sample.phase == .began {
            if let layout = surfaceLayout, layout.zone(x: sample.x, y: sample.y) == .controlSurface {
                recordedTouches[sample.id] = RecordedTouch(
                    point: SIMD2(sample.x, sample.y), at: time, layout: layout, panel: guidePanelRect)
            }
            return
        }
        guard var touch = recordedTouches[sample.id] else { return }
        touch.track(sample)
        if sample.phase == .moved {
            recordedTouches[sample.id] = touch
            return
        }
        recordedTouches[sample.id] = nil
        let elapsed = time - touch.at
        let gap = lastRecordedLift.map { time - $0 }
        lastRecordedLift = time
        let point = touch.point
        let panel = touch.panel
        let travel = touch.farthestMm
        let cancelled = sample.phase == .cancelled
        sessionRecord.noteLater {
            let rect = panel.map { "\($0)" } ?? "none"
            let spacing = gap.map { String(format: "%.3f", $0) } ?? "none"
            return String(
                format: "touch x=%.1f y=%.1f duration_s=%.3f travel_mm=%.2f", point.x, point.y, elapsed, travel)
                + " panel=\(rect) since_lift_s=\(spacing) cancelled=\(cancelled)"
        }
    }

    func log(_ line: String) {
        sessionRecord.note(line)
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

/// A STOP pressed on the phone is, from the press that latched the stop until the stop is released, exactly one of
/// these: never dropped without the operator being told.
enum PressedStop {
    /// `estop` went out on a connection the server had welcomed, or on the listening connection while it was up, and
    /// no `state` the server wrote after reading it has said stopped, or a reset has been asked for from the stop since
    /// one did.
    case sent
    /// A `state` the server wrote after reading that `estop` said stopped (`LiveLinkController.estopConfirmed`).
    case confirmed
    /// It has reached no server: pressed before any connection was welcomed, or the connection went while it was only
    /// sent. The robot is not stopped; `estop` goes out first after the next `welcome`, with the alarm (J7).
    case owed
}

/// What latched E-stop, shown on S4 so a stop the operator did not ask for is not a mystery.
enum StopCause: Equatable {
    /// STOP was pressed on the phone.
    case button
    /// The server stopped because the arm fell too far behind the commanded position.
    case armBehind
    /// The server was already stopped when the link came up, as it is after a connection dropped mid-command.
    case onConnect
    /// Reconnect pressed STOP, with the simulator not responding, before the connection went.
    case reconnect
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
        case .reconnect: return L10n.string("stop.cause_reconnect")
        case .server(let reason): return String(format: L10n.string("stop.cause_server"), reason)
        }
    }
}
