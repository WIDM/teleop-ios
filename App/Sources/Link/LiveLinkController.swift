import Foundation
import simd
import TeleopCore

/// Owns the socket and the timers around one `TeleopLink`. Main queue only.
/// It reports server-side changes as `TeleopAction`s; the session stays the single source of UI state.
final class LiveLinkController {
    /// The phone must not jump: faster than this between two samples ends the hold (same limit as the web app).
    static let maxSpeedMetersPerSecond: Float = 0.8
    static let connectTimeout: TimeInterval = 5
    static let defaultPort = 8765
    /// The server E-stops when the position it is asked for is more than 10 cm from where the arm is
    /// (`pose_tracking_safety_stop`). A server hold is relative to the arm's position when it started, so no
    /// single server hold ever asks for more than this. That holds however slow or stuck the arm is.
    static let maxLeadMeters: Float = 0.08
    /// The server reports no arm position during a hold. When the hand wants more than the limit, the server
    /// hold is ended and restarted this often, which is the only way to learn how far the arm really got.
    static let resyncAfterMs = 1500
    /// Longest wait for the server to finish the old hold during a resync before the operator's hold ends.
    static let resyncTimeoutMs = 1500
    /// A dropped listening connection is opened again this often, without a word to the operator.
    static let observerRetryMs = 2000
    /// With the listening connection up, the link is lost when neither connection has heard anything this long
    /// (I-7). The control connection alone still counts as lost after `TeleopLink.staleAfterMs`.
    static let quietLinkMs = 1200

    var onAction: ((TeleopAction) -> Void)?
    var onLog: ((String) -> Void)?
    /// True while the command is being held back so the arm can catch up.
    var onCatchingUp: ((Bool) -> Void)?
    /// Why the server E-stopped, just before the `stop` action is reported.
    var onServerStop: ((String) -> Void)?
    /// What the operator should feel or hear about the engaged hold and the scene reset.
    var onFeedback: ((FeedbackEvent) -> Void)?
    /// Every `state` from either connection, in the order the server sent them, before the actions it leads to.
    var onState: ((ServerState) -> Void)?
    /// The control connection's `welcome`, with the server run it names.
    var onWelcome: ((String?) -> Void)?
    /// `gripping` changed.
    var onGripping: ((Bool) -> Void)?
    /// A wrist hold's `orient_start` has just gone on the wire, perhaps after waiting behind a finishing hold.
    var onWristStartSent: (() -> Void)?

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
    /// The newest `state` handed on, from either connection.
    private(set) var newestState: ServerState?
    private var timer: Timer?
    private var ticks = 0
    private var openedAtMs = 0
    private var holdStart: SIMD3<Float>?
    private var lastSample: (position: SIMD3<Float>, atMs: Int)?
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
    /// Set while the old server hold is being ended and a new one has not started. `stopped` turns true when
    /// the server confirms the old one finished; the next `state` after that carries the arm position.
    private var resync: (sinceMs: Int, stopped: Bool)?
    private var lastRefusal: (reason: String, atMs: Int)?
    /// The wrist hold whose angle the input rules set: the newest target, streamed at the pose rate through the lead
    /// bound. Nil when none runs.
    private var wristTarget: WristTarget?
    private var leadBound = WristLeadBound()
    /// When the newest `state` from either connection arrived, for the lead bound's freshness.
    private var newestStateAtMs: Int?
    /// A translation hold whose target comes from a button ramp instead of the phone: metres in the frame
    /// `poseUpdate` takes, the whole way asked for since the press.
    private var buttonTarget: (() -> SIMD3<Double>?)?
    /// During a translation hold: where the reported arm point is being sent, robot base frame.
    private(set) var commandedArm: SIMD3<Float>?
    /// The operator's right and forward at the start of the hold, both horizontal.
    private var holdRight = SIMD3<Float>(1, 0, 0)
    private var holdForward = SIMD3<Float>(0, 0, -1)

    /// - Parameters:
    ///   - makeObserverTransport: the listening connection's socket; `makeTransport` when nil.
    ///   - clientName: the app's name and version from its bundle; tests pass a fixed one.
    init(
        makeTransport: @escaping (URL) -> LinkTransport = { WebSocketTransport(url: $0) },
        makeObserverTransport: ((URL) -> LinkTransport)? = nil,
        pose: @escaping () -> simd_float4x4?,
        nowMs: @escaping () -> Int = { Int(Date().timeIntervalSince1970 * 1000) },
        gripperLimits: GripperLimits = RobotProfile.so101Simulator.gripperLimits,
        clientName: String = LiveLinkController.clientName()
    ) {
        self.clientName = clientName
        self.makeTransport = makeTransport
        self.makeObserverTransport = makeObserverTransport ?? makeTransport
        self.pose = pose
        self.nowMs = nowMs
        monitor = FeedbackMonitor(limits: gripperLimits)
    }

    var isOpen: Bool { transport != nil }
    /// The control connection is welcomed and has had its first state.
    var isUp: Bool { link?.ready == true }
    /// The listening connection is up and receiving state.
    var observerUp: Bool { observer?.ready == true }
    /// The operator's hold the feedback belongs to, if one is engaged.
    var engagedHold: Int? { monitor.engagedHold }
    /// A close ended in contact and nothing has opened since, no scene reset and no new server run.
    var gripping: Bool { monitor.gripping }
    /// A scene reset is waiting to go out or for its answer; every start is refused meanwhile.
    var resetPending: Bool { link?.resetPending == true }
    /// Arm tip position from the server's newest state, in the robot base frame. Stale during a hold.
    var armPosition: SIMD3<Float>? { Self.vector(link?.lastEndEffector) }
    /// Task object and goal from the server's newest state, in the world frame (`RobotProfile.inBase` moves them into
    /// the robot base frame).
    var objectPosition: SIMD3<Float>? { Self.vector(link?.lastObject) }
    var goalPosition: SIMD3<Float>? { Self.vector(link?.lastGoal) }

    /// `teleop-ios/<version> (<build>)`, from the bundle's version and build numbers.
    static func clientName(bundle: Bundle = .main) -> String {
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "teleop-ios/\(version) (\(build))"
    }

    /// "host", "host:port" or a full ws:// URL. Nil when it cannot be a server address.
    static func url(from address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let text = trimmed.contains("://") ? trimmed : "ws://" + trimmed
        guard var parts = URLComponents(string: text),
              parts.scheme == "ws" || parts.scheme == "wss",
              let host = parts.host, !host.isEmpty,
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":" }) else { return nil }
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
        let link = TeleopLink(send: { [weak transport] in transport?.send($0) }, now: nowMs)
        self.transport = transport
        self.link = link
        openedAtMs = nowMs()
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
        holdStart = nil
        lastSample = nil
        resetSentAtMs = nil
        lastRefusal = nil
        armAtSegmentStart = nil
        resync = nil
        wristTarget = nil
        buttonTarget = nil
        commandedArm = nil
        newestStateAtMs = nil
        newestState = nil
        leadBound = WristLeadBound()
    }

    /// The app is leaving or returning to the foreground: timers were or will be frozen, so old probes mean nothing.
    func foregroundChanged() { link?.dropProbes() }

    /// False when the hold could not start (no link, or no tracked pose to measure from).
    func startHold(_ params: PoseParams) -> Bool {
        guard let link, let start = pose() else { return false }
        guard link.poseStart(params) else { return false }
        syncStart()
        holdStart = Self.position(start)
        lastSample = (Self.position(start), nowMs())
        holdParams = params
        smoothed = .zero
        (holdRight, holdForward) = Self.operatorAxes(start)
        armProgress = .zero
        resync = nil
        segmentStartedMs = nowMs()
        armAtSegmentStart = Self.vector(link.lastEndEffector)
        return true
    }

    /// A translation hold that follows `target` instead of the phone: no pose, gain, smoothing or speed guard, but
    /// the same lead cap and resync. False when the hold could not start.
    func startButtonHold(_ target: @escaping () -> SIMD3<Double>?) -> Bool {
        guard let link else { return false }
        let params = PoseParams(gain: 1, smoothing: 0)
        guard link.poseStart(params) else { return false }
        syncStart()
        holdStart = nil
        lastSample = nil
        buttonTarget = target
        holdParams = params
        armProgress = .zero
        resync = nil
        segmentStartedMs = nowMs()
        armAtSegmentStart = Self.vector(link.lastEndEffector)
        return true
    }

    func endHold() {
        link?.poseStop()
        monitor.released(.pose)
        holdEnded()
    }

    /// A translation hold runs, from the phone or from a button.
    private var translating: Bool { holdStart != nil || buttonTarget != nil }

    private func holdEnded() {
        holdStart = nil
        buttonTarget = nil
        lastSample = nil
        armAtSegmentStart = nil
        commandedArm = nil
        resync = nil
        onCatchingUp?(false)
    }

    /// Ends the server hold without ending the operator's, to find out where the arm is.
    private func beginResync() {
        link?.poseStop()
        resync = (nowMs(), false)
    }

    /// The old server hold has finished and the server has said where the arm is: start the next one from there.
    private func finishResync() {
        guard let link, translating else { return }
        let now = Self.vector(link.lastEndEffector)
        if let now, let before = armAtSegmentStart {
            // The server turns an offset into base motion as [x, y, −z]; undo that to stay in the sent frame.
            let moved = now - before
            armProgress += SIMD3(moved.x, moved.y, -moved.z)
        }
        resync = nil
        restarting = true
        guard link.poseStart(holdParams) else {
            restarting = false
            onLog?("link: could not continue the hold after a resync")
            emit(monitor.endedByApp(.noAnswer))
            holdEnded()
            onAction?(.holdArmEnd)
            return
        }
        syncStart()
        armAtSegmentStart = now
        segmentStartedMs = nowMs()
    }

    /// Sends `estop` on the control connection and, when it is up, on the listening one too (the server takes it
    /// from either). False when neither was up: nothing reached the robot.
    @discardableResult
    func estop() -> Bool {
        let reached = link?.ready == true || observerUp
        link?.estop()
        if observerUp { observer?.estop() }
        monitor.released()
        endWristTarget()
        holdEnded()
        return reached
    }

    func estopReset() {
        link?.estopReset()
        resetSentAtMs = nowMs()
    }

    /// Asks for a scene reset. False when the link cannot send one now (not ready, or a control still active).
    @discardableResult
    func resetScene() -> Bool {
        link?.resetScene() == true
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
        syncStart()
        return true
    }

    func stopGripper() {
        link?.gripperJogStop()
        monitor.released(.gripper(.open))
    }

    /// A wrist hold whose angle comes from `setWristTarget`. False when the move could not start.
    func startWristHold() -> Bool {
        guard let link, link.orientStart() else { return false }
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
        // translation hold does.
        guard pose() != nil else {
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
        ticks += 1
        tickObserver()
        if !link.ready {
            if nowMs() - openedAtMs > Int(Self.connectTimeout * 1000) { drop("no welcome from server") }
            return
        }
        if link.isStale || bothConnectionsQuiet {
            drop("server went quiet")
            return
        }
        link.service()
        // A start held back past its wait may have just gone out: the lead bound and the input rules learn of it
        // before this tick's wrist update is worked out.
        syncStart()
        // Twice a second: the echo is the only thing the server sends during a hold, so it is also the heartbeat.
        if ticks % (TeleopLink.poseRateHz / 2) == 0 { link.probe() }
        // Every 133 ms while the gripper moves; the server asks for 150 ms and gives up at 750 ms.
        if link.gripperJogActive, ticks % 4 == 0 { link.keepalive() }
        if let resync, translating, nowMs() - resync.sinceMs > Self.resyncTimeoutMs {
            onLog?("link: server did not finish the hold during a resync, hold ended")
            emit(monitor.endedByApp(.noAnswer))
            holdEnded()
            onAction?(.holdArmEnd)
            return
        }
        tickWrist(link)
        syncStart()
        emit(monitor.tick(at: nowMs()))
        guard link.holdActive, let wanted = wantedOffset() else { return }
        let now = nowMs()
        // What is still to do, measured from where the arm was when this server hold started.
        let remaining = wanted - armProgress
        let distance = simd_length(remaining)
        let catchingUp = distance > Self.maxLeadMeters
        let delta = catchingUp ? remaining / distance * Self.maxLeadMeters : remaining
        link.poseUpdate(positionMeters: [Double(delta.x), Double(delta.y), Double(delta.z)])
        syncStart()
        if let start = armAtSegmentStart {
            let target = start + SIMD3(delta.x, delta.y, -delta.z)
            commandedArm = target
            monitor.commanded(SIMD3(Double(target.x), Double(target.y), Double(target.z)))
        }
        onCatchingUp?(catchingUp)
        // The hand wants more than one server hold may ask for: find out where the arm got to and go on from there.
        if catchingUp, now - segmentStartedMs >= Self.resyncAfterMs { beginResync() }
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
            emit(monitor.endedByApp(.tracking))
            onAction?(.holdArmEnd)
            return nil
        }
        let now = nowMs()
        if let last = lastSample, now > last.atMs {
            let speed = simd_distance(current, last.position) / (Float(now - last.atMs) / 1000)
            if speed > Self.maxSpeedMetersPerSecond {
                onLog?(String(format: "link: phone moved too fast (%.2f m/s), hold ended", speed))
                emit(monitor.endedByApp(.tooFast))
                onAction?(.holdArmEnd)
                return nil
            }
        }
        lastSample = (current, now)
        // Low-pass, then scale: smoothing 0 follows the hand exactly, higher values trade lag for a steadier arm.
        let keep = Float(holdParams.smoothing)
        smoothed = smoothed * keep + (current - holdStart) * (1 - keep)
        return Self.serverOffset(smoothed * Float(holdParams.gain), right: holdRight, forward: holdForward)
    }

    private func handle(_ text: String) {
        guard let link else { return }
        let wasWelcomed = link.welcomed
        let received = link.receive(text)
        if !wasWelcomed, link.welcomed { welcomed(link) }
        // A final ack can put a held-back start on the wire.
        syncStart()
        guard let event = received else { return }
        switch event {
        case .up, .state:
            if let state = link.lastState { stateArrived(state, serverMs: link.lastStateServerMs) }
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
            if resync != nil { resync?.stopped = true }
        case .state(let estop, _):
            if let resync, resync.stopped, !estop { finishResync() }
            if !estop {
                resetSentAtMs = nil
            } else if let sent = resetSentAtMs, nowMs() - sent < 2000 {
                break
            } else {
                resetSentAtMs = nil
                // A refusal just before the E-stop is its cause.
                if let refusal = lastRefusal, nowMs() - refusal.atMs < 3000 {
                    onServerStop?(refusal.reason)
                } else {
                    onServerStop?("unknown")
                }
                onAction?(.stop)
            }
        case .latency(let ms):
            monitor.roundTrip(ms: ms)
            onAction?(.linkLatency(ms: ms))
        case .rejected(let type, let reason):
            onLog?("link: \(type) rejected: \(reason)")
            if type == "estop_reset" { resetSentAtMs = nil }
        case .gripperRefused(let reason):
            onLog?("link: gripper refused: \(reason)")
            emit(monitor.startRefused(reason: reason, at: nowMs()))
            onAction?(.gripperEnd)
        case .turnRefused(let reason):
            onLog?("link: wrist hold refused: \(reason)")
            emit(monitor.startRefused(reason: reason, at: nowMs()))
            endWristTarget()
            onAction?(.wristEnd)
        case .holdRefused(let reason):
            onLog?("link: hold ended by server: \(reason)")
            // A success is not the cause of a later emergency stop.
            if reason != TeleopLink.successReason { lastRefusal = (reason, nowMs()) }
            emit(monitor.startRefused(reason: reason, at: nowMs()))
            holdEnded()
            onAction?(.holdArmEnd)
        case .resetDone:
            onLog?("link: scene reset")
            monitor.sceneReset()
            leadBound.sceneReset()
            noteGripping()
            onAction?(.sceneResetDone)
        case .resetRefused(let reason):
            onLog?("link: scene reset refused: \(reason)")
            emit([.notReset])
        }
    }

    private func welcomed(_ link: TeleopLink) {
        monitor.welcomed(session: link.serverSession)
        noteGripping()
        onWelcome?(link.serverSession)
        openObserver()
    }

    private func stateArrived(_ state: ServerState, serverMs: Int?) {
        if let serverMs, let newest = newestStateServerMs, serverMs < newest { return }
        if let serverMs { newestStateServerMs = serverMs }
        newestState = state
        newestStateAtMs = nowMs()
        emit(monitor.observe(state, at: nowMs()))
        noteGripping()
        onState?(state)
    }

    /// Tells the monitor about a start that has just gone on the wire.
    private func syncStart() {
        guard let start = link?.lastStart, start.seq != announcedStart else { return }
        announcedStart = start.seq
        monitor.startSent(start.kind, restart: restarting, at: start.atMs)
        restarting = false
        noteGripping()
        if start.kind == .wrist, wristTarget != nil {
            leadBound.holdStarted(measured: measuredWrist)
            onWristStartSent?()
        }
    }

    private func noteGripping() {
        guard monitor.gripping != reportedGripping else { return }
        reportedGripping = monitor.gripping
        onGripping?(reportedGripping)
    }

    private func emit(_ events: [FeedbackEvent]) {
        for event in events { onFeedback?(event) }
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
        let observer = TeleopLink(send: { [weak transport] in transport?.send($0) }, now: nowMs)
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
            if let state = observer.lastState { stateArrived(state, serverMs: observer.lastStateServerMs) }
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
    }

    private func tickObserver() {
        if let observer {
            if observer.isStale {
                observerDropped("server went quiet")
            } else if !observer.ready, nowMs() - observerOpenedAtMs > Int(Self.connectTimeout * 1000) {
                observerDropped("no welcome")
            }
        }
        if observerTransport == nil, let retry = observerRetryAtMs, nowMs() >= retry, link?.ready == true { openObserver() }
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
    static func serverOffset(_ world: SIMD3<Float>, right: SIMD3<Float>, forward: SIMD3<Float>) -> SIMD3<Float> {
        let offset = OperatorFrame.linkOffset(
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
