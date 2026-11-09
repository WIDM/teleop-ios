import AVFoundation
import CoreMotion

enum SystemPermissions {
    /// Shows the system prompts that have not been answered yet. A denial does not block the flow.
    static func request() async {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        await requestMotion()
    }

    /// Only activity queries raise the Motion prompt; the result itself is not used.
    /// The query's callback was seen not to arrive after an unanswered prompt, so the wait is capped.
    /// Moving on with a prompt still up is harmless; a Continue button stuck forever is not.
    private static func requestMotion() async {
        guard CMMotionActivityManager.isActivityAvailable(),
              CMMotionActivityManager.authorizationStatus() == .notDetermined else { return }
        let manager = CMMotionActivityManager()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            let finish = {
                guard !resumed else { return }
                resumed = true
                continuation.resume()
            }
            manager.queryActivityStarting(from: Date(), to: Date(), to: .main) { _, _ in finish() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { finish() }
        }
        withExtendedLifetime(manager) {}
    }
}
