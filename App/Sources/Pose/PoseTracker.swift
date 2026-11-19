import ARKit
import simd

/// What the tracker asks of the camera session: ARKit's own, or a stand-in that a test drives.
protocol CameraSession: AnyObject {
    /// Runs world tracking from scratch. The new run has a world frame of its own, whose heading is wherever the phone
    /// points when it starts.
    func runResettingTracking()
    func pause()
}

extension ARSession: CameraSession {
    func runResettingTracking() {
        run(ARWorldTrackingConfiguration(), options: [.resetTracking])
    }
}

/// Phone pose from ARKit world tracking, as in COBALT. The session also keeps the camera in use,
/// which iOS requires before it sends volume-key capture events.
final class PoseTracker: NSObject, ARSessionDelegate {
    static let shared: PoseTracker = {
        let session = ARSession()
        let tracker = PoseTracker(
            session: session, isSupported: { ARWorldTrackingConfiguration.isSupported },
            cameraGranted: { AVCaptureDevice.authorizationStatus(for: .video) == .authorized },
            clock: { ProcessInfo.processInfo.systemUptime })
        session.delegate = tracker
        return tracker
    }()

    private let session: CameraSession
    private let supported: () -> Bool
    private let cameraGranted: () -> Bool
    private let clock: () -> TimeInterval
    /// Whether the session runs now. Separate from what the screen wants, so a later camera grant can still start it.
    private var running = false
    /// Latest camera pose in world space; nil until tracking is normal.
    private(set) var current: simd_float4x4?
    /// Every frame: the camera pose while tracking is normal (nil otherwise), and the frame's timestamp on the
    /// uptime clock, the clock touches carry too.
    var onFrame: ((simd_float4x4?, TimeInterval) -> Void)?
    /// The system stopped the camera (true) or gave it back (false). While it is stopped the volume keys change the
    /// volume again and no pose arrives.
    var onInterruption: ((Bool) -> Void)?
    /// The tracker ran the session, with the uptime read just before it did. Every frame stamped after that time is
    /// from the new run, in its new world frame. A pause is not reported.
    var onRun: ((TimeInterval) -> Void)?
    var onRecord: ((String) -> Void)?

    /// `shared` gives ARKit's session and the device's own answers; a test gives a stand-in session, its answers and
    /// its clock. The caller makes the tracker the session's delegate.
    init(
        session: CameraSession, isSupported: @escaping () -> Bool, cameraGranted: @escaping () -> Bool,
        clock: @escaping () -> TimeInterval
    ) {
        self.session = session
        supported = isSupported
        self.cameraGranted = cameraGranted
        self.clock = clock
        super.init()
    }

    var isSupported: Bool { supported() }

    /// Safe to call again (route change, back to the foreground): it only starts or stops on a change.
    func setActive(_ active: Bool) {
        let canRun = active && isSupported && cameraGranted()
        guard canRun != running else { return }
        running = canRun
        if canRun {
            let stamp = clock()
            session.runResettingTracking()
            onRecord?("tracker run stamp=\(stamp)")
            onRun?(stamp)
        } else {
            session.pause()
            onRecord?("tracker pause")
            current = nil
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameArrived(frame.camera.transform, tracked: frame.camera.trackingState.isNormal, stampedAt: frame.timestamp)
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let state: String
        switch camera.trackingState {
        case .normal: state = "normal"
        case .notAvailable: state = "not available"
        case .limited(let reason): state = "limited \(reason)"
        }
        onRecord?("tracker tracking \(state)")
    }

    func sessionWasInterrupted(_ session: ARSession) { interrupted() }

    func sessionInterruptionEnded(_ session: ARSession) { interruptionEnded() }

    /// A frame: its camera pose, whether tracking was normal for it, and its timestamp.
    func frameArrived(_ transform: simd_float4x4, tracked: Bool, stampedAt stamp: TimeInterval) {
        current = tracked ? transform : nil
        onFrame?(current, stamp)
    }

    func interrupted() {
        onRecord?("tracker interrupted")
        current = nil
        onInterruption?(true)
    }

    func interruptionEnded() {
        onRecord?("tracker interruption ended")
        onInterruption?(false)
    }
}

extension ARCamera.TrackingState {
    fileprivate var isNormal: Bool {
        if case .normal = self { return true }
        return false
    }
}

/// What one hold moved the phone by, for the debug log until the real link sends pose updates.
struct PoseDelta: Equatable {
    let translationCm: SIMD3<Float>
    let rotationDegrees: Float

    init(from start: simd_float4x4, to end: simd_float4x4) {
        let move = end.columns.3 - start.columns.3
        translationCm = SIMD3(move.x, move.y, move.z) * 100
        let relative = simd_quatf(start).inverse * simd_quatf(end)
        // A quaternion and its negation are the same turn, so `angle` can read 358° for a 2° turn.
        let angle = relative.angle
        rotationDegrees = min(angle, 2 * .pi - angle) * 180 / .pi
    }

    var logLine: String {
        String(
            format: "pose Δ x %.1f y %.1f z %.1f cm, %.0f°",
            translationCm.x, translationCm.y, translationCm.z, rotationDegrees)
    }
}
