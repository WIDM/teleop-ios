import AVFoundation

enum SystemPermissions {
    /// Shows the camera prompt if it has not been answered yet. A denial does not block the flow.
    static func request() async {
        _ = await AVCaptureDevice.requestAccess(for: .video)
    }
}
