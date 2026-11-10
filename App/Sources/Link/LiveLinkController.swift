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
        return true
    }

    func endHold() {
        link?.poseStop()
        holdStart = nil
        lastSample = nil
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
    func gripper(_ target: GripperState) { link?.gripper(target) }

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
        let delta = current - holdStart
        link.poseUpdate(positionMeters: [Double(delta.x), Double(delta.y), Double(delta.z)])
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

    private static func position(_ transform: simd_float4x4) -> SIMD3<Float> {
        SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    }
}
