import Foundation
import simd
import TeleopCore

/// Owns the socket and the timers around one `TeleopLink`. Main queue only.
/// It reports server-side changes as `TeleopAction`s; the session stays the single source of UI state.
final class LiveLinkController {
    /// The phone must not jump: faster than this between two samples ends the hold (same limit as the web app).
    static let maxSpeedMetersPerSecond: Float = 0.8
    /// The shortest time the speed is measured over: half a pose tick.
    static let speedSampleMs = 1000 / TeleopLink.poseRateHz / 2
    static let connectTimeout: TimeInterval = 5
    static let defaultPort = 8765
    // The server's stop distance (the S4 server's `pose_tracking_safety_stop` is 10 cm), the caps under it and the
    // resync times are the profile's: `robot.motion` and `server`. A server hold is relative to the arm's position when
    // it started, so no single server hold ever asks for more than the cap, however slow or stuck the arm is. The
    // server reports no arm position during a hold: when the hand wants more than the cap, the server hold is ended and
    // restarted after the resync time, which is the only way to learn how far the arm really got.
    /// A dropped listening connection is opened again this often, without a word to the operator.
    static let observerRetryMs = 2000
    /// With the listening connection up, the link is lost when neither connection has heard anything this long
    /// (I-7). The control connection alone counts as lost after `TeleopLink.staleAfterMs`, the same 3 s today, so the
    /// listening connection no longer makes a silent server known sooner. An ordinary wireless network was measured
    /// holding every message back for up to 1.8 s and then delivering them together; 3 s rides that out, and the
    /// server's own watchdog ends a hold whose updates stopped after 0.75 s.
    static let quietLinkMs = 3000
    /// A tick this long after the one before means the app's main thread did not run in between (a long frame, an
    /// accessibility snapshot). What arrived meanwhile still waits behind the tick, so the stall does not count as
    /// silence and no probe's round trip across it counts. The server's watchdog still ends a hold whose updates
    /// stopped.
    static let stalledTickMs = 250
    /// The cause handed on when a release refused during a paused simulator latches the stop here again: the stop was
    /// the operator's, not one the server latched by itself.
    static let releaseRefusedStallReason = "sim_stalled_release"

    var onAction: ((TeleopAction) -> Void)?
    var onWireEvent: ((String, [String: Any], UInt64) -> Void)?
    private var holdAxis: TranslationAxis?
    var onLog: ((String) -> Void)?
    /// True while the command is being held back so the arm can catch up.
    var onCatchingUp: ((Bool) -> Void)?
    /// Why the server E-stopped, just before the `stop` action is reported.
    var onServerStop: ((String) -> Void)?
    /// A stop began on the server, seen on either connection, before any action it leads to. A reset asked for
    /// before it must not go out and clear it.
    var onStopSeen: (() -> Void)?
    /// What the operator should feel or hear about the engaged hold and the scene reset.
    var onFeedback: ((FeedbackEvent) -> Void)?
    /// The first translation of an episode started with the jaws still closed (`JawsClosedReminder`): the screen says
    /// to open them before moving in. Not a cue: nothing is felt or spoken.
    var onOpenJawsFirst: (() -> Void)?
    /// Every `state` from either connection, in the order the server sent them, before the actions it leads to.
    var onState: ((ServerState) -> Void)?
    /// The control connection's `welcome`, with the server run it names.
    var onWelcome: ((String?) -> Void)?
    /// `gripping` changed.
    var onGripping: ((Bool) -> Void)?
    /// A wrist hold's `orient_start` has just gone on the wire, perhaps after waiting behind a finishing hold.
    var onWristStartSent: (() -> Void)?
    /// The running wrist hold takes its angle from the fine panel's wrist buttons, not the phone's rotation.
    private var wristFromPad = false
    /// The simulator's level changed, from the first to the second, as `SimStallDetector` decides.
    var onSimulatorLevel: ((SimStallDetector.Level, SimStallDetector.Level) -> Void)?

    /// How the control connection names itself in the server's log; the listening one adds " observer".
    let clientName: String
    private let makeTransport: (URL) -> LinkTransport
    private let makeObserverTransport: (URL) -> LinkTransport
    private let pose: () -> simd_float4x4?
    private let nowMs: () -> Int
    private var url: URL?
    private var transport: LinkTransport?
    private var link: TeleopLink?
    /// The second connection: it says hello and then only listens, so the server sends it `state` every 200 ms,
    /// holds included. Its closing can never stop the robot: it owns nothing.
    private var observerTransport: LinkTransport?
    private var observer: TeleopLink?
    private var observerOpenedAtMs = 0
    private var observerRetryAtMs: Int?
    private var monitor: FeedbackMonitor
    /// The seq of the newest start the monitor has been told about.
    private var announcedStart: Int?
    private var reportedGripping = false
    /// The next start restarts a hold the operator still holds (a resync).
    private var restarting = false
    /// Server time (`ts`) of the newest state handed on. A state from the other connection that left the server
    /// earlier is older news and is dropped.
    private var newestStateServerMs: Int?
    /// Whether each connection's newest state said stopped, in that connection's own order; nil before its first.
    private var controlStopped: Bool?
    private var observerStopped: Bool?
    /// The newest `state` handed on, from either connection.
    private(set) var newestState: ServerState?
    private var timer: Timer?
    private var ticks = 0
    private var lastTickAtMs: Int?
    private var openedAtMs = 0
    private var holdStart: SIMD3<Float>?
    private var lastSample: (position: SIMD3<Float>, atMs: Int)?
    private var lastMotionRecordAtMs: Int?
    private var lastGripperRecordAtMs: Int?
    private var motionRequest: (offset: SIMD3<Float>, atMs: Int)?
    private var motionUpdate: (delta: SIMD3<Float>, target: SIMD3<Float>?, atMs: Int)?
    /// Set when estop_reset goes out. States sent before the server handled it still say estop, and must not re-latch.
    private var resetSentAtMs: Int?
    /// The server ignores gain and smoothing in translation mode, so they are applied here.
    private var holdParams = PoseParams(gain: 1, smoothing: 0)
    private var smoothed = SIMD3<Float>.zero
    /// How far the arm really moved in earlier server holds of this press, in the frame offsets are sent in.
    private var armProgress = SIMD3<Float>.zero
    /// Arm position (robot base) when the current server hold started; nil if the server has not reported one.
    private var armAtSegmentStart: SIMD3<Float>?
    private var segmentStartedMs = 0
    /// The label the newest state carried when a coordinated-height hold started, when it is one an earlier command
    /// left (`no_solution`, `pose_clamped`) rather than this hold's own. Cleared by the first state with another label.
    private var coordinatedLeftOverLabel: ServerActivity?
    /// Set while the old server hold is being ended and a new one has not started. `stopped` turns true when
    /// the server confirms the old one finished; the next `state` after that carries the arm position.
    private var resync: (sinceMs: Int, startSeq: Int?, stopped: Bool, stoppedServerMs: Int?)?
    private var lastRefusal: (reason: String, atMs: Int)?
    /// The wrist hold whose angle the input rules set: the newest target, streamed at the pose rate through the lead
    /// bound. Nil when none runs.
    private var wristTarget: WristTarget?
    private var leadBound: WristLeadBound
    /// When the newest `state` from either connection arrived, for the lead bound's freshness.
    private var newestStateAtMs: Int?
    /// A translation hold whose target comes from a button ramp instead of the phone: metres in the frame
    /// `poseUpdate` takes, the whole way asked for since the press.
    private var buttonTarget: (() -> SIMD3<Double>?)?
    /// During a translation hold: where the reported arm point is being sent, robot base frame.
    private(set) var commandedArm: SIMD3<Float>?
    private var toolTargets: (intent: SIMD3<Float>, applied: SIMD3<Float>)?
    /// The operator's right and forward at the start of the hold, both horizontal.
    private var holdRight = SIMD3<Float>(1, 0, 0)
    private var holdForward = SIMD3<Float>(0, 0, -1)
    /// The guide's work-area rule, fed the commanded gripper-link point every tick of a translation hold; nil with that
    /// aid off, which is version 1.0.1.
    private var workAreaCue: WorkAreaCue?
    /// The work-area rule has spoken in the operator's current hold: the server's own clamp END for it would tell the
    /// same crossing twice.
    private var workAreaToldThisHold = false
    /// The running translation hold is one nobody holds, such as a follow the input rules latched. Set by AppModel;
    /// cleared when the hold ends here and when the link closes. While it is set, the endings this link causes are told
    /// as the move's own endings, which are queued and never dropped.
    var holdIsLoose = false
    /// The running translation hold is a move to a point the operator tapped, which he does not steer. Set by AppModel
    /// with `holdIsLoose`; cleared with it. A limit such a move meets is told once, by the move's own ending: neither
    /// the work-area rule, the server's clamp END, "Blocked." nor "Can't go lower." plays during it, and the guide
    /// shows no side for it.
    var holdIsGoing = false
    /// Some aid is on: the model sets it from the aids it resolved, and the link does not learn which. With it set, a
    /// translation hold starts from the newest arm position either connection has reported when its start goes on the
    /// wire, not from the control connection's at the press: that connection hears nothing during a hold, so a press
    /// made before the last hold's answer would start from where that hold started, and the commanded point the guide's
    /// rules judge, and the target after the next resync, would be off by that hold's whole travel. Off is version
    /// 1.0.1.
    var anyAidOn = false
    /// How the operator was told of the last ending this link caused of a hold nobody held, until AppModel reads it.
    private var looseEnding: Interruption?
    /// The newest `state` from either connection that carried an arm position. A state without one never makes the
    /// measured arm newer.
    private(set) var newestArmState: ServerState?
    /// When `newestArmState` arrived.
    private var newestArmAtMs: Int?
    /// The newest round trips, as many as the feedback monitor's acceptance time is the median of: half the median is
    /// how long a state took to get here after the server measured it.
    private var roundTrips: [Int] = []
    /// The last command sent was held at the lead cap: the arm is held short of what the hand asks for.
    private var leadCapped = false
    /// The last stop this phone sent whose answer has not been heard: the seq of the start it ended (nil for an
    /// emergency stop) and when it went out. Nil once an arm position the server sent after that answer has come.
    private var stopUnanswered: (start: Int?, sentAtMs: Int)?
    /// The start whose stop was noted last, so one stop still waiting for its answer is noted once.
    private var lastNotedStop: Int?
    /// Whether the simulator behind this connection's server has stopped responding. Starts afresh with every
    /// connection: a reconnect may reach a restarted server.
    private var stall: SimStallDetector
    /// The newest state handed to the stall decision said the server is stopped.
    private(set) var serverSaysStopped = false
    /// Whether the jaws hold an object, which decides the path of the pad's holds (`startPadHold`).
    private var objectHold: ObjectHold
    /// Whether the operator is still owed this episode's reminder to open the jaws before moving in.
    private var jawsReminder: JawsClosedReminder

    /// - Parameters:
    ///   - makeObserverTransport: the listening connection's socket; `makeTransport` when nil.
    ///   - clientName: the app's name and version from its bundle; tests pass a fixed one.
    init(
        makeTransport: @escaping (URL) -> LinkTransport = { WebSocketTransport(url: $0) },
        makeObserverTransport: ((URL) -> LinkTransport)? = nil,
        pose: @escaping () -> simd_float4x4?,
        nowMs: @escaping () -> Int = { Int(Date().timeIntervalSince1970 * 1000) },
        profile: RobotProfile,
        clientName: String = LiveLinkController.clientName()
    ) {
        let gripper = profile.gripper
        let wrist = profile.wrist
        frames = profile.frames
        self.wrist = wrist
        motion = profile.motion
        server = profile.server
        leadBound = WristLeadBound(limits: wrist.lead)
        self.clientName = clientName
        self.makeTransport = makeTransport
        self.makeObserverTransport = makeObserverTransport ?? makeTransport
        self.pose = pose
        self.nowMs = nowMs
        self.gripper = gripper
        objectHold = ObjectHold(heldObjectPoint: profile.server.heldObjectPoint)
        stall = SimStallDetector(detection: profile.server.stallDetection)
        blocked = profile.blocked
        monitor = FeedbackMonitor(
            limits: gripper.limits, frames: frames, blocked: profile.blocked, lowest: profile.lowest)
        jawsReminder = JawsClosedReminder(limits: gripper.limits)
    }

    /// What the jaw's readings mean: the readings that count, the unit the session record writes them in, and the
    /// thresholds the feedback rules judge them by.
    let gripper: GripperProfile

    /// The arm's wrist numbers; the lead bound's come from them.
    let wrist: WristProfile

    /// The button speeds and the caps on how far a command runs ahead of the arm.
    let motion: MotionProfile

    /// The server's stop distance, resync times and the point that holds an object.
    let server: ServerProfile

    /// How old a measured position may be and still say something about now: the blocked rule's freshness.
    let blocked: BlockedRule

    /// The profile's frames: which base axis each direction moves the arm along, and how the link's offsets are signed
    /// against the base frame.
    let frames: Frames

    var isOpen: Bool { transport != nil }
    /// The simulator is paused or not responding: no move, release or reset goes out while it lasts, and the stop
    /// stays latched.
    var simulatorStalled: Bool { stall.stalled }
    var simulatorLevel: SimStallDetector.Level { stall.level }
    /// What paused the simulator; nil while it runs.
    var simulatorStallTrigger: SimStallDetector.Trigger? { stall.trigger }
    var toolCalibrationID: String? { link?.toolCalibrationID }
    var supportsCoordinatedHeight: Bool { link?.supportsCoordinatedHeight == true }
    @discardableResult
    func sendDiagnostic(type: String, payload: [String: Any]) -> Bool {
        link?.sendDiagnostic(type: type, payload: payload) ?? false
    }
    private var measuredControlPoint: SIMD3<Float>? {
        if holdParams.toolCalibrationID != nil { return newestArmState?.toolPoint.map { SIMD3<Float>($0) } }
        return Self.vector(link?.lastEndEffector)
    }
    /// The tool point a tool-point resync restarts from: the newest arm position, fresh, with the simulator running,
    /// the last stop answered and the arm heard since, and the newest state fresh, idle and not stopped. Nil otherwise.
    var freshToolPointForStep: SIMD3<Double>? {
        guard toolCalibrationID != nil, !stall.stalled, armHeardAfterLastStop, link?.unfinishedStop == nil,
            let state = newestState, !state.estop, state.activity == .ok, newestStateServerMs != nil,
            let receivedAt = newestStateAtMs, (0...blocked.freshMs).contains(nowMs() - receivedAt),
            let age = newestArmAgeMs, (0...blocked.freshMs).contains(age)
        else { return nil }
        return newestArmState?.toolPoint
    }

    /// Why a translation hold on the tool point may not start now; nil when it may.
    var manualTranslationStartRefusal: Refusal? { translationStartRefusal(padStart: false) }
    /// The same for a pad or precision-panel button. It differs in one case: a clamp left by a hold that has ended.
    var padStartRefusal: Refusal? { translationStartRefusal(padStart: true) }

    /// Why a free move by the phone (no axis chosen, on the gripper link's path) may not start now; nil when it may:
    /// no link, a simulator that does not run, a scene reset or a success on show, or a stopped server. Unlike a hold
    /// on the tool point it may be pressed while the last stop still waits for its answer: its start waits on the wire
    /// for that answer, as in version 1.0.1, and with an aid on takes its start point when it goes out. The server's
    /// activity label is no reason to refuse it either: the server clamps such a move at a limit, and the label a
    /// clamped hold leaves behind must not keep the next one waiting.
    /// A stop is not judged here either. The newest state can still say stopped for a moment after a release or a
    /// reset the server has already answered, and refusing on it would swallow the first press after the release; the
    /// session knows whether the stop is latched, and a server that is still stopped refuses the start itself.
    var freePhoneStartRefusal: Refusal? { linkStartRefusal }

    /// What keeps every translation hold from starting whatever its path: no link, a simulator that does not run, a
    /// scene reset or a success on show.
    private var linkStartRefusal: Refusal? {
        guard isUp else { return .noLink }
        if stall.stalled { return .simulatorStalled }
        if resetPending || newestState?.simBusy == true { return .notReady }
        return nil
    }

    /// The same, and a stop the newest state reports: the checks of a hold on the tool point.
    private var serverStartRefusal: Refusal? {
        if let refusal = linkStartRefusal { return refusal }
        if newestState?.estop == true { return .emergencyStop }
        return nil
    }

    private func translationStartRefusal(padStart: Bool) -> Refusal? {
        if let refusal = serverStartRefusal { return refusal }
        guard armHeardAfterLastStop, link?.unfinishedStop == nil else { return .busy }
        guard toolCalibrationID != nil else { return nil }
        guard let state = newestState, let receivedAt = newestStateAtMs,
            (0...blocked.freshMs).contains(nowMs() - receivedAt),
            state.endEffector != nil, state.toolPoint != nil
        else { return .noArmData }
        switch state.activity {
        case .ok?, .other("no_solution")?: return nil
        // These labels say the server still runs a control: a start now would be refused as busy, or a tool-point
        // hold would take its start point from an arm still moving. The server keeps `pose_clamped` after a hold that
        // ended clamped until another command writes a new label, though. With no translation hold of this phone
        // running and its last stop answered (checked above), that hold is over and the arm stands where the clamp
        // held it, so the label is no reason to refuse a pad button. Only the pad is let through: its buttons could
        // never clear the label themselves, while a move by the phone can.
        case .poseClamped? where padStart && link?.holdActive != true && !translating: return nil
        case .poseTracking?, .poseClamped?, .orienting?, .orientClamped?, .gripperJogging?, .gripperContact?:
            return .busy
        default: return .notReady
        }
    }

    /// The control connection is welcomed and has had its first state.
    var isUp: Bool { link?.ready == true }
    /// The listening connection is up and receiving state.
    var observerUp: Bool { observer?.ready == true }
    /// On either connection, a `state` saying stopped has come that the server wrote after it read that connection's
    /// newest `estop` (`TeleopLink.estopConfirmed`): a state sent before the `estop` arrived never counts.
    var estopConfirmed: Bool { link?.estopConfirmed == true || observer?.estopConfirmed == true }
    /// The operator's hold the feedback belongs to, if one is engaged.
    var engagedHold: Int? { monitor.engagedHold }
    /// A close ended in contact and nothing has opened since, no scene reset and no new server run.
    var gripping: Bool { monitor.gripping }
    /// The server reported contact for the last close and nothing has let go since: no open the server ran, no scene
    /// reset and no reconnect. An emergency stop keeps it: the jaws stay closed on the object. While it holds, the
    /// pad's holds take the gripper link's path.
    var holdingObject: Bool { objectHold.holding }
    /// A scene reset is waiting to go out or for its answer; every start is refused meanwhile.
    var resetPending: Bool { link?.resetPending == true }
    /// Arm tip position from the server's newest state, in the robot base frame. Stale during a hold.
    var armPosition: SIMD3<Float>? { Self.vector(link?.lastEndEffector) }
    /// Task object and goal from the server's newest state, in the world frame (`RobotProfile.inBase` moves them into
    /// the robot base frame).
    var objectPosition: SIMD3<Float>? { Self.vector(link?.lastObject) }
    var goalPosition: SIMD3<Float>? { Self.vector(link?.lastGoal) }
    /// The side the commanded point is outside the work area on, for the guide's line; nil while inside, with the rule
    /// off, and whenever no translation is being commanded, so the line never shows the last hold's side. Nil during a
    /// move to a tapped point, which the rule does not watch.
    var commandOutside: OperatorDirection? { commandedArm == nil || holdIsGoing ? nil : workAreaCue?.outside }
    /// The lowest gripper-link height, robot base frame, at which the arm stood against a downward command since the
    /// control connection was welcomed, for the guide's lowest line; nil before one and with that rule off.
    var lowestSeen: Double? { monitor.lowestSeen }
    /// The same for the pinch point's height, from stalls whose state carried the server's pinch point; nil before one,
    /// with that rule off, and from a server that reports no pinch point. The guide draws its lowest line from this
    /// when there is one.
    var lowestPinchSeen: Double? { monitor.lowestPinchSeen }
    /// How old the arm position in `newestArmState` is, milliseconds: the time since it arrived, plus half the median
    /// round trip, because the server measured it before sending it. Nil before the first.
    var newestArmAgeMs: Int? {
        guard let arrived = newestArmAtMs else { return nil }
        let median = roundTrips.isEmpty ? 0 : roundTrips.sorted()[roundTrips.count / 2]
        return nowMs() - arrived + median / 2
    }
    /// The link is pausing the translation hold: a start waits behind a finishing hold, the start is being re-sent, or
    /// the command is held at the lead cap. The arm may stand still then for a reason that says nothing about where it
    /// can go.
    var holdPaused: Bool { resync != nil || link?.startHeldBack == true || leadCapped }
    /// An arm position has been heard that the server sent after it finished the last hold this phone ended: one the
    /// operator let go of, one the link stopped to learn where the arm got to, or any hold an emergency stop ended. A
    /// tap waits for it, because a move's path starts at the newest reading and the server starts it from where the arm
    /// stands when it takes the start. True again at the first state with a position on the control connection after
    /// that hold's final ack (the server sends one there right after it, and nothing it sent before can arrive after it
    /// on that connection), or, after an emergency stop, at the first one there that the server wrote after reading the
    /// stop; at any position from either connection once `TeleopLink.finishWaitMs` has passed since the stop, so a lost
    /// answer never leaves taps waiting; and when the link closes. Before that wait a state from the listening
    /// connection never counts: it may have been measured before the stop and still arrive after the answer.
    var armHeardAfterLastStop: Bool { stopUnanswered == nil }

    /// The guide's aids this link runs; nil is version 1.0.1. `gripperBox`: the work box in gripper-link space, robot
    /// base frame, which the server keeps the gripper link inside. `sides`: the faces of that box the work-area rule
    /// tells; one the arm is stopped before (a floor below the table) is left out while another cue tells that stop.
    func guideAidsChanged(
        _ aids: GuideAids?, gripperBox: (low: SIMD3<Double>, high: SIMD3<Double>), sides: Set<OperatorDirection>,
        directionalBlocked: Bool = false
    ) {
        workAreaCue =
            aids?.workAreaWords == true
            ? WorkAreaCue(frames: frames, low: gripperBox.low, high: gripperBox.high, sides: sides) : nil
        workAreaToldThisHold = false
        monitor.reportsLowest = aids?.lowestCue == true
        monitor.blockedWorkspace = directionalBlocked && aids != nil ? gripperBox : nil
    }

    /// `teleop-ios/<version> (<build>) install=<code>`, from the bundle's version and build numbers and this install's
    /// code, so a study can tell one phone's sessions from another's without knowing whose phone it is.
    static func clientName(bundle: Bundle = .main, defaults: UserDefaults = .standard) -> String {
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "teleop-ios/\(version) (\(build)) install=\(installCode(defaults: defaults))"
    }

    static let installCodeKey = "installCode"

    /// Eight random hex digits made the first time they are asked for and kept until the app is deleted. Nothing in
    /// it comes from the phone or the person. It lives in the app's settings, so a phone restored from another's
    /// backup carries the same code; declared in PrivacyInfo.xcprivacy as a device identifier, linked to the install, not used for tracking.
    static func installCode(defaults: UserDefaults = .standard) -> String {
        if let code = defaults.string(forKey: installCodeKey) { return code }
        let code = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        defaults.set(code, forKey: installCodeKey)
        return code
    }

    /// "host", "host:port" or a full ws:// URL. Nil when it cannot be a server address.
    static func url(from address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let text = trimmed.contains("://") ? trimmed : "ws://" + trimmed
        guard var parts = URLComponents(string: text),
            parts.scheme == "ws" || parts.scheme == "wss",
            let host = parts.host, !host.isEmpty,
            host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":" })
        else { return nil }
        if parts.port == nil { parts.port = defaultPort }
        return parts.url
    }

    /// Opens a new socket, dropping any old one quietly. False when the address is not usable.
    @discardableResult
    func connect(to address: String) -> Bool {
        guard let url = Self.url(from: address) else { return false }
        closeQuietly()
        self.url = url
        let transport = makeTransport(url)
        let link = TeleopLink(
            send: { [weak transport] in transport?.send($0) }, now: nowMs, jawReadings: gripper.validReadings)
        link.onReceivedEnvelope = { [weak self] type, payload in
            self?.onWireEvent?(type, payload, DispatchTime.now().uptimeNanoseconds)
        }
        self.transport = transport
        self.link = link
        openedAtMs = nowMs()
        // The timer starts now: a first tick far later than one interval is a stall too.
        lastTickAtMs = openedAtMs
        transport.onText = { [weak self, weak transport] text in
            guard let self, self.transport === transport else { return }
            self.handle(text)
        }
        transport.onClose = { [weak self, weak transport] in
            guard let self, self.transport === transport else { return }
            self.drop("socket closed")
        }
        transport.open()
        link.hello(name: clientName)
        onLog?("link: connecting \(url.absoluteString)")
        let timer = Timer(timeInterval: 1.0 / Double(TeleopLink.poseRateHz), repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        return true
    }

    /// The user's own disconnect: no `linkLost` is reported.
    func closeQuietly() {
        timer?.invalidate()
        timer = nil
        link?.poseStop()
        link?.gripperJogStop()
        link?.orientStop()
        link?.transportClosed()
        transport?.close()
        transport = nil
        link = nil
        url = nil
        closeObserver()
        observerRetryAtMs = nil
        monitor.linkClosed()
        announcedStart = nil
        restarting = false
        newestStateServerMs = nil
        controlStopped = nil
        observerStopped = nil
        holdStart = nil
        holdAxis = nil
        lastSample = nil
        resetSentAtMs = nil
        lastRefusal = nil
        armAtSegmentStart = nil
        resync = nil
        wristTarget = nil
        buttonTarget = nil
        commandedArm = nil
        toolTargets = nil
        newestStateAtMs = nil
        newestState = nil
        leadBound = WristLeadBound(limits: wrist.lead)
        lastTickAtMs = nil
        holdIsLoose = false
        holdIsGoing = false
        looseEnding = nil
        newestArmState = nil
        newestArmAtMs = nil
        leadCapped = false
        stopUnanswered = nil
        lastNotedStop = nil
        stall = SimStallDetector(detection: server.stallDetection)
        serverSaysStopped = false
        closeAfterStop = nil
        objectHold.apply(.reconnected)
    }

    /// The app is leaving or returning to the foreground: timers were or will be frozen, so old probes mean nothing,
    /// and time away does not count toward the simulator's waits.
    func foregroundChanged(_ active: Bool) {
        link?.dropProbes()
        observeStall(active ? .foreground : .background)
    }

    /// False when the hold could not start (no link, or no tracked pose to measure from).
    func startHold(_ params: PoseParams, axis: TranslationAxis? = nil) -> Bool {
        guard let link, let start = pose() else { return false }
        if axis != nil || params.toolCalibrationID != nil {
            guard let calibration = link.toolCalibrationID, params.toolCalibrationID == calibration,
                manualTranslationStartRefusal == nil
            else { return false }
        } else if freePhoneStartRefusal != nil {
            return false
        }
        holdAxis = axis
        holdParams = params
        guard link.poseStart(params) else { holdAxis = nil; return false }
        noteStopSent()
        syncStart()
        holdStart = Self.position(start)
        lastSample = (Self.position(start), nowMs())
        holdParams = params
        smoothed = .zero
        (holdRight, holdForward) = Self.operatorAxes(start)
        armProgress = .zero
        resync = nil
        segmentStartedMs = nowMs()
        // With an aid on the start point is taken when the start goes on the wire, which may be later.
        if !anyAidOn || params.toolCalibrationID != nil { armAtSegmentStart = measuredControlPoint }
        translationStarted()
        return true
    }

    /// A translation hold that follows `target` instead of the phone: no pose, gain, smoothing or speed guard, but
    /// the same lead cap and resync. False when the hold could not start.
    func startButtonHold(
        useToolPoint: Bool = false, toolMotion: PoseToolMotion? = nil, padStart: Bool = false,
        _ target: @escaping () -> SIMD3<Double>?
    ) -> Bool {
        guard let link else { return false }
        if useToolPoint, toolCalibrationID == nil || translationStartRefusal(padStart: padStart) != nil {
            return false
        }
        let params = PoseParams(
            gain: 1, smoothing: 0, toolCalibrationID: useToolPoint ? link.toolCalibrationID : nil,
            toolMotion: toolMotion)
        guard link.poseStart(params) else { return false }
        holdParams = params
        noteStopSent()
        syncStart()
        holdStart = nil
        holdAxis = nil
        lastSample = nil
        buttonTarget = target
        armProgress = .zero
        resync = nil
        segmentStartedMs = nowMs()
        // With an aid on the start point is taken when the start goes on the wire, which may be later.
        if !anyAidOn || params.toolCalibrationID != nil { armAtSegmentStart = measuredControlPoint }
        translationStarted()
        return true
    }

    /// A hold of a pad or precision-panel direction button, up and down included, following the button's ramp. Its path
    /// is `ObjectHold.padHoldPath`: the tool point while nothing is held, the gripper link's once the jaws hold an
    /// object. Wherever the server has a tool calibration the start is refused for the reasons of
    /// `padStartRefusal` on either path. False when the hold could not start.
    func startPadHold(vertical: Bool, _ target: @escaping () -> SIMD3<Double>?) -> Bool {
        if toolCalibrationID != nil, padStartRefusal != nil { return false }
        let path = objectHold.padHoldPath(
            toolCalibrated: toolCalibrationID != nil, coordinatedHeight: supportsCoordinatedHeight, vertical: vertical)
        return startButtonHold(
            useToolPoint: path.useToolPoint, toolMotion: path.toolMotion, padStart: true, target)
    }

    /// The operator's translation hold has started (not a resync's restart, which stays the same hold): the work-area
    /// rule may tell every side again.
    private func translationStarted() {
        let label = newestArmState?.activity
        coordinatedLeftOverLabel =
            holdParams.toolMotion == .coordinatedHeight && (label == .other("no_solution") || label == .poseClamped)
            ? label : nil
        motionRequest = nil
        motionUpdate = nil
        workAreaCue?.holdStarted()
        workAreaToldThisHold = false
    }

    func endHold() {
        link?.poseStop()
        noteStopSent()
        monitor.released(.pose)
        holdEnded()
    }

    /// A translation hold runs, from the phone or from a button.
    private var translating: Bool { holdStart != nil || buttonTarget != nil }

    private func holdEnded() {
        coordinatedLeftOverLabel = nil
        holdStart = nil
        holdAxis = nil
        buttonTarget = nil
        lastSample = nil
        armAtSegmentStart = nil
        commandedArm = nil
        toolTargets = nil
        resync = nil
        holdIsLoose = false
        holdIsGoing = false
        leadCapped = false
        onCatchingUp?(false)
    }

    /// How the operator was told of the ending this link just caused of a hold nobody held, read once by AppModel as
    /// the session drops the hold; nil when this link recorded none.
    func takeLooseEnding() -> Interruption? {
        defer { looseEnding = nil }
        return looseEnding
    }

    /// Ends the server hold without ending the operator's, to find out where the arm is.
    private func beginResync() {
        link?.poseStop()
        noteStopSent()
        monitor.resyncBegan()
        resync = (nowMs(), link?.unfinishedStop?.start, false, nil)
        // No command goes out until the start is re-sent, so none is held at the cap; the re-sent start is the pause.
        leadCapped = false
    }

    /// The old server hold has finished and the server has said where the arm is: start the next one from there.
    private func finishResync(after state: ServerState, serverMs: Int?) {
        guard let link, translating, let pending = resync else { return }
        if nowMs() - pending.sinceMs > server.resync.timeoutMs
            || (holdParams.toolCalibrationID != nil && holdParams.toolCalibrationID != link.toolCalibrationID)
        {
            onLog?("link: valid stopped tool state unavailable before resync deadline, hold ended")
            endedTranslation(monitor.endedByApp(.noAnswer))
            holdEnded()
            onAction?(.holdArmEnd)
            return
        }
        if holdParams.toolCalibrationID != nil,
            !confirmsToolResync(state, serverMs: serverMs) || freshToolPointForStep == nil
                || newestState?.simBusy == true
        {
            return
        }
        if holdParams.toolCalibrationID == nil, !confirmsOriginResync(state, serverMs: serverMs) { return }
        let now = measuredControlPoint
        if let now, let before = armAtSegmentStart {
            // The server turns an offset into base motion with each axis signed (`Frames.linkSigns`); undo that to stay in
            // the sent frame.
            armProgress += frames.link(fromBase: now - before)
        }
        resync = nil
        restarting = true
        guard link.poseStart(holdParams) else {
            restarting = false
            if link.startsBlocked {
                // The simulator stopped while the old hold finished: the hold ends as the server's refusal would end it.
                onLog?("link: the simulator stopped, the hold is not continued after a resync")
                endedTranslation(stalledRefusal(), serverReason: TeleopLink.simulatorStalledReason)
                holdEnded()
                onAction?(.holdArmEnd)
                return
            }
            onLog?("link: could not continue the hold after a resync")
            endedTranslation(monitor.endedByApp(.noAnswer))
            holdEnded()
            onAction?(.holdArmEnd)
            return
        }
        syncStart()
        armAtSegmentStart = now
        segmentStartedMs = nowMs()
    }

    /// A resync on the gripper link's path restarts only from an arm position in a state the server wrote after the
    /// stop it answered: an older state, or one without an arm position, would leave the travel of the stopped hold
    /// uncounted, and the restart would ask for it again. The state's activity label is no reason to wait: a hold
    /// held at a limit leaves `pose_clamped` behind.
    private func confirmsOriginResync(_ state: ServerState, serverMs: Int?) -> Bool {
        guard state.endEffector != nil else { return false }
        guard let stoppedAt = resync?.stoppedServerMs, let serverMs else { return true }
        return serverMs >= stoppedAt
    }

    private func confirmsToolResync(_ state: ServerState, serverMs: Int?) -> Bool {
        guard let stoppedAt = resync?.stoppedServerMs, let serverMs, serverMs >= stoppedAt,
            state.activity == .ok, !state.estop, !state.simBusy,
            state.endEffector != nil, state.toolPoint != nil
        else { return false }
        return true
    }

    /// Sends `estop` on the control connection and, when it is up, on the listening one too (the server takes it
    /// from either). True when it reached a server: the control connection has had its `welcome`, so the server reads
    /// what follows on it, or the listening connection is up. False before the `welcome` (the server may still refuse
    /// the `hello`): the `estop` goes out again at the `welcome`.
    @discardableResult
    func estop() -> Bool {
        let reached = link?.welcomed == true || observerUp
        link?.estop()
        if observerUp { observer?.estop() }
        stopUnanswered = (nil, nowMs())
        monitor.released()
        endWristTarget()
        holdEnded()
        return reached
    }

    func estopReset() {
        guard link?.estopReset() == true else { return }
        resetSentAtMs = nowMs()
    }

    /// How long Reconnect waits for the server to confirm its `estop` before the connection closes all the same.
    static let reconnectStopWaitMs = 1000
    /// Reconnect's wait: the connection stays until the server confirms the `estop` or `reconnectStopWaitMs` has
    /// passed, since closing at once can cancel the message before it leaves. `done` runs once, with whether the server
    /// confirmed it.
    private var closeAfterStop: (sinceMs: Int, done: (Bool) -> Void)?
    /// True while Reconnect waits for its stop to be confirmed.
    var waitingToCloseAfterStop: Bool { closeAfterStop != nil }

    /// Runs `done` once the server has confirmed the stop just sent, or after `reconnectStopWaitMs` without it; the
    /// caller closes the connection then. A connection closed first in any other way ends the wait without it: the
    /// stop it carried is owed then, as any unconfirmed STOP is.
    func whenStopConfirmed(_ done: @escaping (_ confirmed: Bool) -> Void) {
        closeAfterStop = (nowMs(), done)
        settleCloseAfterStop()
    }

    /// Ends Reconnect's wait when the server has confirmed the stop or the wait is over. True when it ended.
    @discardableResult
    private func settleCloseAfterStop() -> Bool {
        guard let wait = closeAfterStop else { return false }
        let confirmed = estopConfirmed
        guard confirmed || nowMs() - wait.sinceMs >= Self.reconnectStopWaitMs else { return false }
        closeAfterStop = nil
        wait.done(confirmed)
        return true
    }

    /// Asks for a scene reset. False when the link cannot send one now (not ready, a control still active, or the
    /// simulator not responding: a server could clear its stop for a reset that never runs).
    @discardableResult
    func resetScene() -> Bool {
        guard link?.resetScene() == true else { return false }
        // The loop is silent for seconds while the scene resets: that silence is no sign.
        observeStall(.resetRequested)
        return true
    }

    /// The scene was reset (an `ok scene_reset`, a new episode or a new server run): no wrist lead is left.
    func sceneWasReset() {
        leadBound.sceneReset()
    }

    /// The gripper travels toward `target` while its control is held. Holding past the end is harmless:
    /// the server clamps at the joint limit and stops squeezing on contact. False when the move could not start.
    @discardableResult
    func startGripper(_ target: GripperState) -> Bool {
        guard let link, link.gripperJogStart(target) else { return false }
        onLog?("grip-edge start target=\(target) " + measuredControlRecord(newestState))
        noteStopSent()
        syncStart()
        return true
    }

    func stopGripper() {
        if link?.gripperJogActive == true {
            onLog?("grip-edge stop " + measuredControlRecord(newestState))
        }
        link?.gripperJogStop()
        noteStopSent()
        monitor.released(.gripper(.open))
    }

    /// A wrist hold whose angle comes from `setWristTarget`. False when the move could not start.
    func startWristHold(fromPad: Bool = false) -> Bool {
        guard let link, link.orientStart() else { return false }
        noteStopSent()
        wristFromPad = fromPad
        wristTarget = .identity
        syncStart()
        return true
    }

    /// The running wrist hold's target from now on, before the lead bound.
    func setWristTarget(_ target: WristTarget) {
        guard wristTarget != nil else { return }
        wristTarget = target
    }

    func stopWristHold() {
        link?.orientStop()
        noteStopSent()
        monitor.released(.wrist)
        endWristTarget()
    }

    private func endWristTarget() {
        guard wristTarget != nil else { return }
        wristTarget = nil
        leadBound.holdEnded(measured: measuredWrist)
    }

    /// The newest measured wrist angles from either connection.
    private var measuredWrist: WristReadings {
        WristReadings(rollDeg: newestState?.wristRollDeg, flexDeg: newestState?.wristFlexDeg)
    }

    private func tickWrist(_ link: TeleopLink) {
        guard let target = wristTarget, link.turnActive else { return }
        // The target is the phone's rotation; with no tracked pose that is no longer known, so the hold ends, as a
        // translation hold does. The fine panel's wrist buttons set the angle without the phone.
        guard wristFromPad || pose() != nil else {
            onLog?("link: tracking lost, wrist hold ended")
            emit(monitor.endedByApp(.tracking))
            endWristTarget()
            onAction?(.wristEnd)
            return
        }
        let age = newestStateAtMs.map { nowMs() - $0 }
        let sent = leadBound.bounded(target, measured: measuredWrist, ageMs: age)
        switch sent.axis {
        case .tilt?: link.orientUpdate(pitchDegrees: sent.degrees)
        case .turn?, nil: link.orientUpdate(rollDegrees: sent.axis == nil ? 0 : sent.degrees)
        }
    }

    /// Runs at the pose rate. Internal so tests can drive it without a timer.
    func tick() {
        guard let link else { return }
        // Reconnect's wait may end here, closing the connection.
        if settleCloseAfterStop() { return }
        defer {
            recordMotion()
            recordGripper()
        }
        let tickedAt = nowMs()
        if let last = lastTickAtMs, tickedAt - last > Self.stalledTickMs {
            let stall = tickedAt - last - 1000 / TeleopLink.poseRateHz
            link.stalled(forMs: stall)
            observer?.stalled(forMs: stall)
        }
        lastTickAtMs = tickedAt
        ticks += 1
        tickObserver()
        if !link.ready {
            if nowMs() - openedAtMs > Int(Self.connectTimeout * 1000) { drop("no welcome or first state from server") }
            return
        }
        if link.isStale || bothConnectionsQuiet {
            drop("server went quiet")
            return
        }
        observeStall(.tick)
        link.service()
        // A start held back past its wait may have just gone out: the lead bound and the input rules learn of it
        // before this tick's wrist update is worked out.
        syncStart()
        // Twice a second: the echo is the only thing the server sends during a hold, so it is also the heartbeat.
        if ticks % (TeleopLink.poseRateHz / 2) == 0 { link.probe() }
        // Every 133 ms while the gripper moves; the server asks for 150 ms and gives up at 750 ms.
        if link.gripperJogActive, ticks % 4 == 0 { link.keepalive() }
        if let resync, translating, nowMs() - resync.sinceMs > server.resync.timeoutMs {
            onLog?("link: server did not finish the hold during a resync, hold ended")
            endedTranslation(monitor.endedByApp(.noAnswer))
            holdEnded()
            onAction?(.holdArmEnd)
            return
        }
        tickWrist(link)
        syncStart()
        emit(monitor.tick(at: nowMs()))
        guard link.holdActive, let wanted = wantedOffset() else { return }
        let now = nowMs()
        motionRequest = (wanted, now)
        if holdParams.toolMotion == .coordinatedHeight {
            updateCoordinatedHeight(wanted, link: link, at: now)
            return
        }
        // What is still to do, measured from where the arm was when this server hold started.
        let remaining = wanted - armProgress
        let distance = simd_length(remaining)
        let toolControl = holdParams.toolCalibrationID != nil
        let maxLead = toolControl ? motion.toolMaxLeadM : motion.maxLeadM
        let catchingUp = distance > maxLead
        leadCapped = catchingUp
        let delta = catchingUp ? remaining / distance * maxLead : remaining
        link.poseUpdate(positionMeters: [Double(delta.x), Double(delta.y), Double(delta.z)])
        syncStart()
        if let start = armAtSegmentStart {
            let target = start + frames.base(fromLink: delta)
            if toolControl {
                if !link.startHeldBack {
                    let intent = start + frames.base(fromLink: remaining)
                    toolTargets = (intent, target)
                    monitor.commanded(SIMD3<Double>(intent), point: .tool)
                }
            } else {
                poseCommandSent(target, at: now)
            }
        }
        if !link.startHeldBack {
            motionUpdate = (delta, commandedArm, now)
        }
        onCatchingUp?(catchingUp)
        // The hand wants more than one server hold may ask for: find out where the arm got to and go on from there.
        let resyncAfter = toolControl ? server.resync.toolAfterMs : server.resync.afterMs
        if catchingUp, now - segmentStartedMs >= resyncAfter { beginResync() }
    }

    private func updateCoordinatedHeight(_ wanted: SIMD3<Float>, link: TeleopLink, at now: Int) {
        func stop(_ events: [FeedbackEvent]) {
            link.poseStop()
            noteStopSent()
            endedTranslation(events)
            holdEnded()
            onAction?(.holdArmEnd)
        }
        // Until the first state with a label of its own, for at most the freshness time, the label an earlier command
        // left says nothing about this hold: a refusal before it, or the clamp that ended the hold before.
        let waitingOutLeftOverLabel =
            coordinatedLeftOverLabel != nil
            && (0...blocked.freshMs).contains(now - segmentStartedMs)
            && newestArmState?.activity == coordinatedLeftOverLabel
        // The hold moves the tool along up only: the link axis that is up carries the offset, the other two stay zero.
        let up = frames.up.axis.index
        guard let start = armAtSegmentStart, let state = newestArmState,
            let measured = state.toolPoint, let age = newestArmAgeMs,
            (0...blocked.freshMs).contains(age), !state.estop, !state.simBusy,
            newestState?.estop != true, newestState?.simBusy != true,
            (0..<3).allSatisfy({ $0 == up || wanted[$0] == 0 }), wanted[up].isFinite
        else {
            onLog?("link: coordinated height has no fresh vertical tracking state, hold ended")
            stop(monitor.endedByApp(.noAnswer))
            return
        }
        guard state.activity == .ok || state.activity == .poseTracking || waitingOutLeftOverLabel else {
            if state.activity == .other("no_solution"), coordinatedLeftOverLabel != .other("no_solution") {
                onLog?("link: coordinated height ended by server no_solution")
                lastRefusal = ("no_solution", now)
                stop(monitor.startRefused(reason: "no_solution", at: now))
            } else {
                onLog?("link: coordinated height has no current tracking state, hold ended")
                stop(monitor.endedByApp(.noAnswer))
            }
            return
        }
        let progress = Float(frames.linkSigns[up]) * (Float(measured[up]) - start[up])
        let remaining = wanted[up] - progress
        let lead = min(max(remaining, -motion.toolMaxLeadM), motion.toolMaxLeadM)
        var delta = SIMD3<Float>.zero
        delta[up] = progress + lead
        leadCapped = abs(remaining) > motion.toolMaxLeadM
        link.poseUpdate(positionMeters: [Double(delta.x), Double(delta.y), Double(delta.z)])
        syncStart()
        if !link.startHeldBack {
            let intent = start + frames.base(fromLink: wanted)
            let target = start + frames.base(fromLink: delta)
            toolTargets = (intent, target)
            monitor.commanded(SIMD3<Double>(intent), point: .tool)
            motionUpdate = (delta, commandedArm, now)
        }
        onCatchingUp?(leadCapped)
    }

    private func recordMotion() {
        guard translating, let onLog else { return }
        let now = nowMs()
        guard lastMotionRecordAtMs.map({ now - $0 >= 1000 }) ?? true else { return }
        lastMotionRecordAtMs = now
        func vector(_ value: SIMD3<Float>?) -> String {
            guard let value else { return "none" }
            return String(format: "[%.4f,%.4f,%.4f]", value.x, value.y, value.z)
        }
        func age(_ stamp: Int?) -> String { stamp.map { String(max(0, now - $0)) } ?? "none" }
        let measured = newestArmState?.endEffector.map { SIMD3<Float>($0) }
        onLog(
            "motion source=\(buttonTarget == nil ? "phone" : "button_or_tap") "
                + "link_frame=\(frames.linkFrameName) units=m "
                + "wanted_link=\(vector(motionRequest?.offset)) wanted_age_ms=\(age(motionRequest?.atMs)) "
                + "sent_link=\(vector(motionUpdate?.delta)) sent_target_base=\(vector(motionUpdate?.target)) "
                + "sent_age_ms=\(age(motionUpdate?.atMs)) measured_base=\(vector(measured)) "
                + "measured_received_age_ms=\(age(newestArmAtMs)) cap=\(leadCapped) "
                + "resync=\(resync != nil) start_wait=\(link?.startHeldBack == true) "
                + "gain=\(holdParams.gain) smoothing=\(holdParams.smoothing) "
                + "tool_intent_base=\(vector(toolTargets?.intent)) tool_applied_base=\(vector(toolTargets?.applied)) "
                + measuredControlRecord(newestArmState))
    }

    private func measuredControlRecord(_ state: ServerState?) -> String {
        func number(_ value: Double?) -> String {
            value.map { String(format: "%.4f", $0) } ?? "none"
        }
        let tool =
            state?.toolPoint.map {
                "[\(number($0.x)),\(number($0.y)),\(number($0.z))]"
            } ?? "none"
        let activity = state?.activity.map { String(describing: $0) } ?? "none"
        return "tool_base=\(tool) wrist_flex_deg=\(number(state?.wristFlexDeg)) "
            + "wrist_roll_deg=\(number(state?.wristRollDeg)) jaw_deg=\(number(state?.gripperDeg)) "
            + "jaw_unit=\(gripper.unit.symbol) server_activity=\(activity)"
    }

    private func recordGripper() {
        guard link?.gripperJogActive == true, let onLog else {
            lastGripperRecordAtMs = nil
            return
        }
        let now = nowMs()
        guard lastGripperRecordAtMs.map({ now - $0 >= 1000 }) ?? true else { return }
        lastGripperRecordAtMs = now
        let age = newestStateAtMs.map { String(max(0, now - $0)) } ?? "none"
        onLog("grip measured_received_age_ms=\(age) " + measuredControlRecord(newestState))
    }

    /// Records the target carried by a pose update in robot-base coordinates.
    func poseCommandSent(_ target: SIMD3<Float>, at now: Int) {
        commandedArm = target
        let point = SIMD3<Double>(target)
        monitor.commanded(point)
        // A move to a tapped point is not fed to the work-area rule: its ending tells a limit it meets.
        if !holdIsGoing, let side = workAreaCue?.commanded(point, at: now) {
            workAreaToldThisHold = true
            emit([.commandOutside(side)])
        }
    }

    /// What the running translation hold asks for in all, in the frame offsets are sent in: the button ramp's
    /// target, or the phone's movement since the start, smoothed and scaled. Nil when there is nothing to send now;
    /// a phone that lost tracking or jumped ends the hold.
    private func wantedOffset() -> SIMD3<Float>? {
        if let buttonTarget {
            return buttonTarget().map { SIMD3(Float($0.x), Float($0.y), Float($0.z)) }
        }
        guard let holdStart else { return nil }
        guard let current = pose().map(Self.position) else {
            onLog?("link: tracking lost, hold ended")
            endedTranslation(monitor.endedByApp(.tracking))
            onAction?(.holdArmEnd)
            return nil
        }
        let now = nowMs()
        if let last = lastSample {
            // Over a gap of a millisecond or two (a late timer tick, a tick right after the press) an ordinary step of
            // the hand reads as a jump. Such a tick keeps the older sample and sends nothing, so every position sent
            // has had its speed judged.
            guard now - last.atMs >= Self.speedSampleMs else { return nil }
            let speed = simd_distance(current, last.position) / (Float(now - last.atMs) / 1000)
            if speed > Self.maxSpeedMetersPerSecond {
                onLog?(String(format: "link: phone moved too fast (%.2f m/s), hold ended", speed))
                endedTranslation(monitor.endedByApp(.tooFast))
                onAction?(.holdArmEnd)
                return nil
            }
        }
        lastSample = (current, now)
        // Low-pass, then scale: smoothing 0 follows the hand exactly, higher values trade lag for a steadier arm.
        let keep = Float(holdParams.smoothing)
        smoothed = smoothed * keep + (current - holdStart) * (1 - keep)
        let scaled = smoothed * Float(holdParams.gain)
        if let axis = holdAxis {
            return SIMD3<Float>(
                axis.project(
                    right: Double(simd_dot(scaled, holdRight)), forward: Double(simd_dot(scaled, holdForward)),
                    up: Double(scaled.y), frames: frames))
        }
        return Self.serverOffset(scaled, right: holdRight, forward: holdForward, frames: frames)
    }

    private func handle(_ text: String) {
        guard let link else { return }
        let wasWelcomed = link.welcomed
        let received = link.receive(text)
        if let seq = link.lastAckSeq { observeStall(.stopAnswered(start: seq)) }
        switch received {
        case .up?, .state?:
            if let state = link.lastState { observeStop(state, last: &controlStopped) }
        default:
            break
        }
        if !wasWelcomed, link.welcomed { welcomed(link) }
        // A final ack can put a held-back start on the wire.
        syncStart()
        guard let event = received else { return }
        switch event {
        case .up, .state:
            if let state = link.lastState {
                stateArrived(state, serverMs: link.lastStateServerMs, onControl: true, health: link.lastStateHealth)
            }
        default:
            break
        }
        switch event {
        case .up(let estop, let gripper):
            onLog?("link: up")
            onAction?(.linkUp(gripper: gripper))
            if estop {
                onServerStop?("on_connect")
                onAction?(.stop)
            }
        case .holdStopped:
            if resync != nil {
                resync?.stopped = true
                if let data = text.data(using: .utf8),
                    let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                {
                    resync?.stoppedServerMs = envelope["ts"] as? Int
                }
            }
        case .state(let estop, _):
            if let resync, resync.stopped, !estop, let state = link.lastState {
                finishResync(after: state, serverMs: link.lastStateServerMs)
            }
            if !estop {
                resetSentAtMs = nil
            } else if let sent = resetSentAtMs, nowMs() - sent < 2000 {
                break
            } else {
                resetSentAtMs = nil
                // A refusal just before the E-stop is its cause.
                if let refusal = lastRefusal, nowMs() - refusal.atMs < 3000 {
                    onServerStop?(refusal.reason)
                } else if link.lastStateHealth?.simStalled == true {
                    // The state that brought the stop says the server's simulation loop has stopped.
                    onServerStop?(TeleopLink.simulatorStalledReason)
                } else {
                    onServerStop?("unknown")
                }
                onAction?(.stop)
            }
        case .latency(let ms):
            monitor.roundTrip(ms: ms)
            roundTrips.append(ms)
            if roundTrips.count > FeedbackMonitor.roundTripWindow {
                roundTrips.removeFirst(roundTrips.count - FeedbackMonitor.roundTripWindow)
            }
            onAction?(.linkLatency(ms: ms))
        case .dismissed(let reason):
            onLog?("link: server dismissed this phone: \(reason.rawValue)")
            onAction?(.dismissed(reason))
        case .rejected(let type, let reason):
            onLog?("link: \(type) rejected: \(reason)")
            observeStall(.refused(request: type, reason: reason))
            if type == "estop_reset" {
                resetSentAtMs = nil
                // The server is still stopped, and with the simulator not responding it will stay so: the stop latches
                // again here at once, without waiting for a state to say it.
                if stall.stalled {
                    onServerStop?(Self.releaseRefusedStallReason)
                    onAction?(.stop)
                }
            }
            if type == "pose_start", let pending = resync, let startSeq = pending.startSeq,
                let data = text.data(using: .utf8),
                let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let payload = envelope["payload"] as? [String: Any], payload["seq"] as? Int == startSeq
            {
                lastRefusal = (reason, nowMs())
                endedTranslation(monitor.startRefused(reason: reason, at: nowMs()), serverReason: reason)
                holdEnded()
                onAction?(.holdArmEnd)
            }
        case .gripperRefused(let reason):
            // A refused start and a live hold the watchdog ended both come back as a rejected final answer.
            onLog?("link: gripper hold ended by server: \(reason)")
            if link.lastStart?.kind == .gripper(.open) { objectHold.apply(.openRefused) }
            observeStall(.refused(request: "gripper_jog_start", reason: reason))
            emit(monitor.startRefused(reason: reason, at: nowMs()))
            onAction?(.gripperEnd)
        case .turnRefused(let reason):
            onLog?("link: wrist hold ended by server: \(reason)")
            observeStall(.refused(request: "orient_start", reason: reason))
            emit(monitor.startRefused(reason: reason, at: nowMs()))
            endWristTarget()
            onAction?(.wristEnd)
        case .holdRefused(let reason):
            onLog?("link: hold ended by server: \(reason)")
            observeStall(.refused(request: "pose_start", reason: reason))
            // A success is not the cause of a later emergency stop.
            if reason != TeleopLink.successReason { lastRefusal = (reason, nowMs()) }
            endedTranslation(monitor.startRefused(reason: reason, at: nowMs()), serverReason: reason)
            holdEnded()
            onAction?(.holdArmEnd)
        case .resetDone:
            onLog?("link: scene reset")
            monitor.sceneReset()
            objectHold.apply(.sceneReset)
            jawsReminder.sceneReset()
            leadBound.sceneReset()
            noteGripping()
            onAction?(.sceneResetDone)
        case .resetRefused(let reason):
            onLog?("link: scene reset refused: \(reason)")
            observeStall(.refused(request: "reset_scene", reason: reason))
            emit([.notReset])
        }
    }

    private func welcomed(_ link: TeleopLink) {
        monitor.welcomed(session: link.serverSession)
        jawsReminder.reconnected()
        noteGripping()
        onWelcome?(link.serverSession)
        openObserver()
    }

    /// A stop began on the server, as far as a reset is concerned: a state saying stopped after one that said not
    /// stopped, or the first, on either connection in that connection's own order. Deliberately coarse: the same
    /// stop reported by both connections, or the report of the phone's own STOP, counts again. That only drops a
    /// reset begun in the moment before such a report arrives (the operator holds the top band again), and it can
    /// never take a newer stop for an older one. Runs before the state's actions, so a reset asked for before the
    /// stop is dropped before anything can fire it.
    private func observeStop(_ state: ServerState, last: inout Bool?) {
        defer { last = state.estop }
        guard state.estop, last != true else { return }
        if link?.noteStopSeen() == true { emit([.notReset]) }
        onStopSeen?()
    }

    func stateArrived(_ state: ServerState, serverMs: Int?, onControl: Bool, health: StateHealth? = nil) {
        let toolResync = resync != nil && holdParams.toolCalibrationID != nil
        if onControl, toolResync, confirmsToolResync(state, serverMs: serverMs) {
            armHeard(onControl: true)
        }
        if let serverMs, let newest = newestStateServerMs, serverMs < newest { return }
        if let serverMs { newestStateServerMs = serverMs }
        // Only a state not older than one already seen tells how the simulator is: the other connection's late copy,
        // without timing of its own, would otherwise report a stall long over.
        if let health {
            serverSaysStopped = state.estop
            observeStall(.state(health))
        }
        newestState = state
        if state.activity != coordinatedLeftOverLabel { coordinatedLeftOverLabel = nil }
        newestStateAtMs = nowMs()
        if state.endEffector != nil {
            newestArmState = state
            newestArmAtMs = nowMs()
            if !toolResync { armHeard(onControl: onControl) }
        }
        var events = monitor.observe(state, at: nowMs())
        objectHold.stateArrived(state)
        jawsReminder.stateArrived(state)
        if events.contains(.contact) { objectHold.apply(.contactReported) }
        // During a move to a tapped point the operator steers nothing: a limit the move meets is told once, by its own
        // ending. So the server's clamp of it plays no END and tells no side, and an arm held short of the command is
        // not told "Blocked." either: after a re-sent start the server can say it clamped before the monitor takes
        // that label as this hold's, and the monitor's stall rule would then speak in place of the clamp. Nor is a
        // move that comes down onto something told "Can't go lower.": the monitor still keeps the height it stood
        // at, as for a told cue, so the guide's lowest line is drawn as it would be after one.
        if holdIsGoing {
            events.removeAll { $0 == .limit(.workspace) || $0 == .limit(.blocked) || $0 == .limit(.lowest) }
        }
        // The server clamps at the face, the work-area rule only past its slack, so pushed slowly the clamp comes
        // first. With the commanded point past a face the rule watches, the clamp is that crossing: the rule tells it
        // now, in place of the server's END.
        if events.contains(.limit(.workspace)), let point = commandedArm,
            let clamp = workAreaCue?.serverClamped(SIMD3<Double>(point), at: nowMs()), clamp.foreseen
        {
            events.removeAll { $0 == .limit(.workspace) }
            if let side = clamp.told {
                workAreaToldThisHold = true
                events.append(.commandOutside(side))
            }
        }
        // With the commanded point past only a face the rule does not watch (a floor below the table), the push is one
        // the lowest rule tells, as the table stops the arm before that face; the server's END would be a second cue.
        // Only while that rule runs: without it the END is the push's only cue.
        if monitor.reportsLowest, events.contains(.limit(.workspace)), let point = commandedArm,
            workAreaCue?.isPastOnlyUnwatchedFaces(SIMD3<Double>(point)) == true
        {
            events.removeAll { $0 == .limit(.workspace) }
        }
        // Once the work-area rule has told a side in this hold, the server's clamp END is not played again until the
        // operator's next hold: the clamp of the crossing told would be a second buzz. A clamp past no face of the
        // profile's box (a server whose box differs from the profile's) is dropped then too.
        if workAreaToldThisHold { events.removeAll { $0 == .limit(.workspace) } }
        emit(events)
        noteGripping()
        onState?(state)
    }

    /// A stop may have just gone on the wire: until the server's answer to it has been heard, a tap waits.
    private func noteStopSent() {
        guard let stop = link?.unfinishedStop, stop.start != lastNotedStop else { return }
        lastNotedStop = stop.start
        stopUnanswered = (stop.start, stop.sentAtMs)
        observeStall(.stopSent(start: stop.start))
    }

    /// Hands one input to the stall decision and reports a change of the fact.
    private func observeStall(_ input: SimStallDetector.Input) {
        let before = stall.level
        let changed = stall.observe(input, at: nowMs())
        // Every start, reset and release is checked against this where it would go on the wire.
        link?.startsBlocked = stall.stalled
        guard changed else { return }
        let why = stall.trigger.map { " (\($0.rawValue))" } ?? ""
        let loopAge = link?.lastStateHealth?.loopAgeMs.map { " loop_age_ms=\(Int($0))" } ?? ""
        onLog?("link: simulator \(before) -> \(stall.level)\(why)\(loopAge)")
        onSimulatorLevel?(before, stall.level)
    }

    /// A state with an arm position was handed on. It ends the wait for the last stop's answer when it came on the
    /// control connection after that answer, or once the link's own wait for the answer has run out.
    private func armHeard(onControl: Bool) {
        guard let stop = stopUnanswered else { return }
        var answered = false
        if onControl, let link {
            answered = stop.start.map { link.unfinishedStop?.start != $0 } ?? link.estopConfirmed
        }
        if answered || nowMs() - stop.sentAtMs >= TeleopLink.finishWaitMs { stopUnanswered = nil }
    }

    /// Tells the monitor about a start that has just gone on the wire and, with an aid on, takes a translation hold's
    /// start point then.
    private func syncStart() {
        endDroppedStarts()
        guard let start = link?.lastStart, start.seq != announcedStart else { return }
        announcedStart = start.seq
        // A resync's restart takes its start point from the answer it waited for, as it always has.
        if anyAidOn, start.kind == .pose, !restarting {
            armAtSegmentStart =
                holdParams.toolCalibrationID == nil
                ? newestArmState?.endEffector.map { SIMD3<Float>($0) }
                : measuredControlPoint
        }
        let operatorStart = !restarting
        feedbackStartSent(start.kind, restart: restarting, at: start.atMs)
        restarting = false
        noteGripping()
        if start.kind == .pose, operatorStart { remindToOpenJawsFirst() }
        if start.kind == .wrist, wristTarget != nil {
            leadBound.holdStarted(measured: measuredWrist)
            onWristStartSent?()
        }
    }

    /// What the link kept off the wire because the simulator stopped, after it had been accepted to wait: each control
    /// ends here as the server's `sim_stalled` refusal would end it, and a waiting reset is told as not done.
    private func endDroppedStarts() {
        guard let link else { return }
        for dropped in link.takeDropped() {
            onLog?("link: \(dropped) not sent: the simulator stopped")
            switch dropped {
            case .start(.pose):
                endedTranslation(stalledRefusal(), serverReason: TeleopLink.simulatorStalledReason)
                holdEnded()
                onAction?(.holdArmEnd)
            case .start(.gripper(let target)):
                if target == .open { objectHold.apply(.openRefused) }
                emit(stalledRefusal())
                onAction?(.gripperEnd)
            case .start(.wrist):
                emit(stalledRefusal())
                endWristTarget()
                onAction?(.wristEnd)
            case .resetScene:
                emit([.notReset])
            }
        }
    }

    /// How a press the stopped simulator kept back is told: as the server's refusal of an engaged hold, or felt as a
    /// refusal when nothing was engaged yet.
    private func stalledRefusal() -> [FeedbackEvent] {
        let events = monitor.startRefused(reason: TeleopLink.simulatorStalledReason, at: nowMs())
        return events.isEmpty ? [.refused(.simulatorStalled)] : events
    }

    private func noteGripping() {
        guard monitor.gripping != reportedGripping else { return }
        reportedGripping = monitor.gripping
        onGripping?(reportedGripping)
    }

    /// Starts feedback for a command sent on the wire, keeping the operator hold across resyncs.
    func feedbackStartSent(_ kind: ControlKind, restart: Bool, at now: Int) {
        monitor.startSent(kind, restart: restart, at: now)
        // The open lets go of the object only once a state shows the jaws opening (`ObjectHold.stateArrived`).
        if kind == .gripper(.open) { objectHold.apply(.openSent) }
    }

    /// What the reminder says still holds: the newest state shows the jaws closed, and they hold nothing.
    var jawsClosedWithNothingHeld: Bool {
        !objectHold.holding && !monitor.gripping
            && JawsClosedReminder.jawsClosed(
                newestState?.gripper, degrees: newestState?.gripperDeg, limits: jawsReminder.limits) == true
    }

    /// A translation the operator started has gone on the wire: the first of an episode with the jaws still closed as
    /// it began shows, once, to open them before moving in. Shown only, never a cue; decided after the start, so the
    /// move is never held back.
    private func remindToOpenJawsFirst() {
        let look = JawsClosedReminder.Look(
            jaws: newestState?.gripper, jawDeg: newestState?.gripperDeg, holding: objectHold.holding,
            gripping: monitor.gripping, stopped: serverSaysStopped || newestState?.estop == true,
            simulatorHalted: stall.stalled)
        if jawsReminder.translationStarted(look) { onOpenJawsFirst?() }
    }

    /// Hands events to AppModel. While the hold is one nobody holds, a let-go or a refusal of it becomes the move's own
    /// ending, through conversions that name every reason, so a new reason does not compile without one; a refusal
    /// another cue tells becomes nothing. Every other event passes unchanged. Events go out one by one: in this file an
    /// array literal returned with a case in front is what the session-safety check reads as a session action.
    private func emit(_ events: [FeedbackEvent]) {
        for event in events {
            switch (holdIsLoose, event) {
            case (true, .letGo(let reason)):
                onFeedback?(.drive(.ended(DriveEnd(byLink: reason))))
            case (true, .refused(let refusal)):
                if let end = DriveEnd(refused: refusal) { onFeedback?(.drive(.ended(end))) }
            case (true, .serverRefusal(let refusalClass, _)):
                onFeedback?(.drive(DriveCue(server: refusalClass)))
            default:
                onFeedback?(event)
            }
        }
    }

    /// Each place that ends a translation hold here and reports `.holdArmEnd` tells its events through this, in place
    /// of `emit`, keeping its own order of `holdEnded` and the action. For a hold someone holds it is `emit`. For one
    /// nobody holds it also records whether the operator has been told: a let-go or a refusal became the move's ending,
    /// or became nothing because another cue tells it (a stopped robot: the alarm), or the server's reason is told
    /// elsewhere (a success by its narration, an emergency stop or a stopped robot by the alarm). A reason told
    /// elsewhere gives the move no ending of its own, before or after the hold was accepted, so the one cue is the
    /// other one. Anything else is recorded as unnamed, so the input rules say "Stopped here.".
    private func endedTranslation(_ events: [FeedbackEvent], serverReason: String? = nil) {
        guard holdIsLoose else { return emit(events) }
        let converted = events.contains(where: Self.endsTheHold)
        let toldElsewhere = serverReason.map(FeedbackMonitor.isToldElsewhere) ?? false
        emit(toldElsewhere ? events.filter { !Self.endsTheHold($0) } : events)
        looseEnding = converted || toldElsewhere ? .announced : .unnamed
    }

    /// A let-go or a refusal: what the link says when a hold it ran has ended.
    private static func endsTheHold(_ event: FeedbackEvent) -> Bool {
        switch event {
        case .letGo, .refused, .serverRefusal: return true
        default: return false
        }
    }

    // MARK: Listening connection

    /// The listening connection is up and neither connection has heard anything for `quietLinkMs`.
    private var bothConnectionsQuiet: Bool {
        guard observerUp, let control = link?.quietMs, let listening = observer?.quietMs else { return false }
        return min(control, listening) > Self.quietLinkMs
    }

    private func openObserver() {
        guard let url, observerTransport == nil else { return }
        let transport = makeObserverTransport(url)
        let observer = TeleopLink(
            send: { [weak transport] in transport?.send($0) }, now: nowMs, jawReadings: gripper.validReadings)
        observer.onReceivedEnvelope = { [weak self] type, payload in
            guard type == "state" else { return }
            self?.onWireEvent?(type, payload, DispatchTime.now().uptimeNanoseconds)
        }
        observerTransport = transport
        self.observer = observer
        observerOpenedAtMs = nowMs()
        observerRetryAtMs = nil
        transport.onText = { [weak self, weak transport] text in
            guard let self, self.observerTransport === transport else { return }
            self.handleObserver(text)
        }
        transport.onClose = { [weak self, weak transport] in
            guard let self, self.observerTransport === transport else { return }
            self.observerDropped("socket closed")
        }
        transport.open()
        observer.hello(name: clientName + " observer")
    }

    private func handleObserver(_ text: String) {
        guard let observer, let event = observer.receive(text) else { return }
        switch event {
        case .up, .state:
            if let state = observer.lastState { observeStop(state, last: &observerStopped) }
        default:
            break
        }
        switch event {
        case .up, .state:
            if let state = observer.lastState {
                stateArrived(
                    state, serverMs: observer.lastStateServerMs, onControl: false, health: observer.lastStateHealth)
            }
        default:
            break
        }
    }

    /// Closes the listening connection and opens it again after `observerRetryMs`, without a word to the operator.
    private func observerDropped(_ why: String) {
        closeObserver()
        observerRetryAtMs = nowMs() + Self.observerRetryMs
        onLog?("link: listening connection lost (\(why))")
    }

    private func closeObserver() {
        observer?.transportClosed()
        observerTransport?.close()
        observerTransport = nil
        observer = nil
        observerStopped = nil
    }

    private func tickObserver() {
        if let observer {
            if observer.isStale {
                observerDropped("server went quiet")
            } else if !observer.ready, nowMs() - observerOpenedAtMs > Int(Self.connectTimeout * 1000) {
                observerDropped("no welcome or first state from server")
            }
        }
        if observerTransport == nil, let retry = observerRetryAtMs, nowMs() >= retry, link?.ready == true {
            openObserver()
        }
    }

    private func drop(_ why: String) {
        closeQuietly()
        onLog?("link: lost (\(why))")
        onAction?(.linkLost)
    }

    /// Right and forward as the operator holding the phone sees them, flattened to the floor.
    /// Upright phone: the camera looks forward. Phone lying flat: its top edge points forward.
    /// Adding both directions before flattening covers either grip and everything between.
    static func operatorAxes(_ camera: simd_float4x4) -> (right: SIMD3<Float>, forward: SIMD3<Float>) {
        let axes = PhoneAxes(camera)
        var forward = axes.view + axes.top
        forward.y = 0
        forward = simd_length(forward) > 0.01 ? simd_normalize(forward) : SIMD3(0, 0, -1)
        return (simd_cross(forward, SIMD3(0, 1, 0)), forward)
    }

    /// World offset (ARKit: y up) to the offset the server expects: the hand's right, forward and up, mapped by the
    /// operator frame the buttons use too.
    static func serverOffset(
        _ world: SIMD3<Float>, right: SIMD3<Float>, forward: SIMD3<Float>, frames: Frames
    ) -> SIMD3<Float> {
        let offset = frames.linkOffset(
            right: Double(simd_dot(world, right)), forward: Double(simd_dot(world, forward)), up: Double(world.y)
        )
        return SIMD3(Float(offset.x), Float(offset.y), Float(offset.z))
    }

    private static func vector(_ values: [Double]?) -> SIMD3<Float>? {
        values.map { SIMD3(Float($0[0]), Float($0[1]), Float($0[2])) }
    }

    private static func position(_ transform: simd_float4x4) -> SIMD3<Float> {
        SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    }
}
