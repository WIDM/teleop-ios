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

    var onAction: ((TeleopAction) -> Void)?
    var onLog: ((String) -> Void)?
    /// What the arm is being asked to do during a hold, as the operator sees it: metres right, forward and up.
    /// Nil when the hold ends.
    var onOffset: ((SIMD3<Float>?) -> Void)?

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
        return true
    }

    func endHold() {
        link?.poseStop()
        holdStart = nil
        lastSample = nil
        onOffset?(nil)
    }

    func estop() {
        link?.estop()
        holdStart = nil
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
        let delta = Self.serverOffset(smoothed * Float(holdParams.gain), right: holdRight, forward: holdForward)
        link.poseUpdate(positionMeters: [Double(delta.x), Double(delta.y), Double(delta.z)])
        // serverOffset negates all three, so this is right, forward, up again.
        onOffset?(-delta)
    }

    private func handle(_ text: String) {
        guard let event = link?.receive(text) else { return }
        switch event {
        case .up(let estop, let gripper):
            onLog?("link: up")
            onAction?(.linkUp(gripper: gripper))
            if estop { onAction?(.stop) }
        case .state(let estop, _):
            if !estop {
                resetSentAtMs = nil
            } else if let sent = resetSentAtMs, nowMs() - sent < 2000 {
                break
            } else {
                resetSentAtMs = nil
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
            holdStart = nil
            lastSample = nil
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
        let view = -SIMD3(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z)
        let top = SIMD3(camera.columns.1.x, camera.columns.1.y, camera.columns.1.z)
        var forward = view + top
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

    private static func position(_ transform: simd_float4x4) -> SIMD3<Float> {
        SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    }
}
