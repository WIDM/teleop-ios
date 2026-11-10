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

    var onAction: ((TeleopAction) -> Void)?
    var onLog: ((String) -> Void)?
    /// What the arm is being asked to do during a hold, as the operator sees it: metres right, forward and up.
    /// Nil when the hold ends.
    var onOffset: ((SIMD3<Float>?) -> Void)?
    /// True while the command is being held back so the arm can catch up.
    var onCatchingUp: ((Bool) -> Void)?
    /// Where the cube or the goal is from the gripper; nil when the server has not said.
    var onGuidance: ((Guidance?) -> Void)?
    /// Why the server E-stopped, just before the `stop` action is reported.
    var onServerStop: ((String) -> Void)?

    private let makeTransport: (URL) -> LinkTransport
    private let pose: () -> simd_float4x4?
    private let nowMs: () -> Int
    private var transport: LinkTransport?
    private var link: TeleopLink?
    private var timer: Timer?
    private var ticks = 0
    private var openedAtMs = 0
    private var holdStart: SIMD3<Float>?
    private var lastSample: (position: SIMD3<Float>, atMs: Int)?
    /// Set when estop_reset goes out. States sent before the server handled it still say estop, and must not re-latch.
    private var resetSentAtMs: Int?
    /// The server ignores gain and smoothing in translation mode, so they are applied here.
    private var holdParams = PoseParams(gain: 1, deadbandDegrees: 0, smoothing: 0)
    private var smoothed = SIMD3<Float>.zero
    /// How far the arm really moved in earlier server holds of this press, in the frame offsets are sent in.
    private var armProgress = SIMD3<Float>.zero
    /// Arm position (robot base) when the current server hold started; nil if the server has not reported one.
    private var armAtSegmentStart: SIMD3<Float>?
    private var segmentStartedMs = 0
    /// Set while the old server hold is being ended and a new one has not started. `stopped` turns true when
    /// the server confirms the old one finished; the next `state` after that carries the arm position.
    private var resync: (sinceMs: Int, stopped: Bool)?
    /// A resync found the arm had not moved while being asked to: it is at the edge of its range.
    private var atEdge = false
    private var lastRefusal: (reason: String, atMs: Int)?
    /// The operator's right and forward at the start of the hold, both horizontal.
    private var holdRight = SIMD3<Float>(1, 0, 0)
    private var holdForward = SIMD3<Float>(0, 0, -1)

    init(
        makeTransport: @escaping (URL) -> LinkTransport = { WebSocketTransport(url: $0) },
        pose: @escaping () -> simd_float4x4?,
        nowMs: @escaping () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.makeTransport = makeTransport
        self.pose = pose
        self.nowMs = nowMs
    }

    var isOpen: Bool { transport != nil }
    /// Arm tip position from the server's newest state, in the robot base frame. Stale during a hold.
    var armPosition: SIMD3<Float>? { Self.vector(link?.lastEndEffector) }
    /// Task object and goal from the server's newest state, robot base frame.
    var cubePosition: SIMD3<Float>? { Self.vector(link?.lastObject) }
    var goalPosition: SIMD3<Float>? { Self.vector(link?.lastGoal) }

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
        link.hello()
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
        link?.transportClosed()
        transport?.close()
        transport = nil
        link = nil
        holdStart = nil
        lastSample = nil
        resetSentAtMs = nil
        lastRefusal = nil
        armAtSegmentStart = nil
        resync = nil
        atEdge = false
        onGuidance?(nil)
    }

    /// The app is leaving or returning to the foreground: timers were or will be frozen, so old probes mean nothing.
    func foregroundChanged() { link?.dropProbes() }

    /// False when the hold could not start (no link, or no tracked pose to measure from).
    func startHold(_ params: PoseParams) -> Bool {
        guard let link, let start = pose() else { return false }
        guard link.poseStart(params) else { return false }
        holdStart = Self.position(start)
        lastSample = (Self.position(start), nowMs())
        holdParams = params
        smoothed = .zero
        (holdRight, holdForward) = Self.operatorAxes(start)
        armProgress = .zero
        resync = nil
        atEdge = false
        segmentStartedMs = nowMs()
        armAtSegmentStart = Self.vector(link.lastEndEffector)
        return true
    }

    func endHold() {
        link?.poseStop()
        holdEnded()
    }

    private func holdEnded() {
        holdStart = nil
        lastSample = nil
        armAtSegmentStart = nil
        resync = nil
        onOffset?(nil)
        onCatchingUp?(false)
    }

    /// Ends the server hold without ending the operator's, to find out where the arm is.
    private func beginResync() {
        link?.poseStop()
        resync = (nowMs(), false)
    }

    /// The old server hold has finished and the server has said where the arm is: start the next one from there.
    private func finishResync() {
        guard let link, holdStart != nil else { return }
        let now = Self.vector(link.lastEndEffector)
        if let now, let before = armAtSegmentStart {
            // The server turns an offset into base motion as [x, y, −z]; undo that to stay in the sent frame.
            let moved = now - before
            armProgress += SIMD3(moved.x, moved.y, -moved.z)
            // Asked for the full limit for a second and a half and went nowhere: the server is clamping it.
            atEdge = simd_length(moved) < 0.005
        }
        resync = nil
        guard link.poseStart(holdParams) else {
            onLog?("link: could not continue the hold after a resync")
            holdEnded()
            onAction?(.holdArmEnd)
            return
        }
        armAtSegmentStart = now
        segmentStartedMs = nowMs()
    }

    func estop() {
        link?.estop()
        holdEnded()
    }

    func estopReset() {
        link?.estopReset()
        resetSentAtMs = nowMs()
    }

    func resetScene() { link?.resetScene() }
    /// The gripper travels toward `target` while its control is held. Holding past the end is harmless:
    /// the server clamps at the joint limit and stops squeezing on contact.
    func startGripper(_ target: GripperState) { link?.gripperJogStart(target) }
    func stopGripper() { link?.gripperJogStop() }

    /// Runs at the pose rate. Internal so tests can drive it without a timer.
    func tick() {
        guard let link else { return }
        ticks += 1
        if !link.ready {
            if nowMs() - openedAtMs > Int(Self.connectTimeout * 1000) { drop("no welcome from server") }
            return
        }
        if link.isStale {
            drop("server went quiet")
            return
        }
        // Twice a second: the echo is the only thing the server sends during a hold, so it is also the heartbeat.
        if ticks % (TeleopLink.poseRateHz / 2) == 0 { link.probe() }
        // Every 133 ms while the gripper moves; the server asks for 150 ms and gives up at 750 ms.
        if link.gripperJogActive, ticks % 4 == 0 { link.keepalive() }
        if let resync, holdStart != nil, nowMs() - resync.sinceMs > Self.resyncTimeoutMs {
            onLog?("link: server did not finish the hold during a resync, hold ended")
            holdEnded()
            onAction?(.holdArmEnd)
            return
        }
        guard link.holdActive, let holdStart else { return }
        guard let current = pose().map(Self.position) else {
            onLog?("link: tracking lost, hold ended")
            onAction?(.holdArmEnd)
            return
        }
        let now = nowMs()
        if let last = lastSample, now > last.atMs {
            let speed = simd_distance(current, last.position) / (Float(now - last.atMs) / 1000)
            if speed > Self.maxSpeedMetersPerSecond {
                onLog?(String(format: "link: phone moved too fast (%.2f m/s), hold ended", speed))
                onAction?(.holdArmEnd)
                return
            }
        }
        lastSample = (current, now)
        // Low-pass, then scale: smoothing 0 follows the hand exactly, higher values trade lag for a steadier arm.
        let keep = Float(holdParams.smoothing)
        smoothed = smoothed * keep + (current - holdStart) * (1 - keep)
        let wanted = Self.serverOffset(smoothed * Float(holdParams.gain), right: holdRight, forward: holdForward)
        // What is still to do, measured from where the arm was when this server hold started.
        let remaining = wanted - armProgress
        let distance = simd_length(remaining)
        let catchingUp = distance > Self.maxLeadMeters
        let delta = catchingUp ? remaining / distance * Self.maxLeadMeters : remaining
        link.poseUpdate(positionMeters: [Double(delta.x), Double(delta.y), Double(delta.z)])
        // serverOffset negates all three, so this is right, forward, up again.
        onOffset?(-(armProgress + delta))
        onCatchingUp?(catchingUp)
        // No arm position arrives during a hold, so guide from where the arm is being sent.
        if let start = armAtSegmentStart { publishGuidance(arm: start + SIMD3(delta.x, delta.y, -delta.z)) }
        // The hand wants more than one server hold may ask for: find out where the arm got to and go on from there.
        if catchingUp, now - segmentStartedMs >= Self.resyncAfterMs { beginResync() }
    }

    private func handle(_ text: String) {
        guard let event = link?.receive(text) else { return }
        switch event {
        case .up(let estop, let gripper):
            onLog?("link: up")
            onAction?(.linkUp(gripper: gripper))
            if let arm = armPosition { publishGuidance(arm: arm) }
            if estop {
                onServerStop?("on_connect")
                onAction?(.stop)
            }
        case .holdStopped:
            if resync != nil { resync?.stopped = true }
        case .state(let estop, _):
            if let resync, resync.stopped, !estop { finishResync() }
            if holdStart == nil, let arm = armPosition { publishGuidance(arm: arm) }
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
            onAction?(.linkLatency(ms: ms))
        case .rejected(let type, let reason):
            onLog?("link: \(type) rejected: \(reason)")
            if type == "estop_reset" { resetSentAtMs = nil }
        case .gripperRefused(let reason):
            onLog?("link: gripper refused: \(reason)")
            onAction?(.gripperEnd)
        case .holdRefused(let reason):
            onLog?("link: hold ended by server: \(reason)")
            lastRefusal = (reason, nowMs())
            holdEnded()
            onAction?(.holdArmEnd)
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

    /// World offset (ARKit: y up) to the offset the server expects.
    /// The server was calibrated on a WebXR phone (mapping `phone_axes_20261025_v1`): it turns what it receives
    /// into robot-base motion as [x, y, −z], and wants right → −X, forward → −Y (onto the table), up → +Z.
    /// So right, forward and up each go out negated on x, y and z.
    static func serverOffset(_ world: SIMD3<Float>, right: SIMD3<Float>, forward: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(-simd_dot(world, right), -simd_dot(world, forward), -world.y)
    }

    private func publishGuidance(arm: SIMD3<Float>) {
        guard let link, let cube = Self.vector(link.lastObject), let goal = Self.vector(link.lastGoal) else {
            onGuidance?(nil)
            return
        }
        var guidance = Guidance.make(arm: arm, cube: cube, goal: goal, gripper: link.lastGripper)
        guidance.atEdge = atEdge && holdStart != nil
        onGuidance?(guidance)
    }

    private static func vector(_ values: [Double]?) -> SIMD3<Float>? {
        values.map { SIMD3(Float($0[0]), Float($0[1]), Float($0[2])) }
    }

    private static func position(_ transform: simd_float4x4) -> SIMD3<Float> {
        SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    }
}
