import ARKit
import simd

/// Phone pose from ARKit world tracking, as in COBALT. The session also keeps the camera in use,
/// which iOS requires before it sends volume-key capture events.
final class PoseTracker: NSObject, ARSessionDelegate {
    static let shared = PoseTracker()

    private let session = ARSession()
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

    override private init() {
        super.init()
        session.delegate = self
    }

    var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    /// Safe to call again (route change, back to the foreground): it only starts or stops on a change.
    func setActive(_ active: Bool) {
        let canRun = active && isSupported && AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        guard canRun != running else { return }
        running = canRun
        if canRun {
            session.run(ARWorldTrackingConfiguration(), options: [.resetTracking])
        } else {
            session.pause()
            current = nil
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if case .normal = frame.camera.trackingState {
            current = frame.camera.transform
        } else {
            current = nil
        }
        onFrame?(current, frame.timestamp)
    }

    func sessionWasInterrupted(_ session: ARSession) {
        current = nil
        onInterruption?(true)
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        onInterruption?(false)
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
        String(format: "pose Δ x %.1f y %.1f z %.1f cm, %.0f°",
               translationCm.x, translationCm.y, translationCm.z, rotationDegrees)
    }
}
