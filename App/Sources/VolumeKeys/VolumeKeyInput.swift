import AVFoundation
import AVKit
import SwiftUI
import TeleopCore

/// Keeps one camera session running while any screen needs the volume keys.
/// iOS sends hardware key events only to apps that are actively capturing.
final class CameraKeeper {
    static let shared = CameraKeeper()
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "teleop.camera")
    private var users = 0
    private var configured = false

    func acquire() {
        users += 1
        guard users == 1 else { return }
        queue.async { [self] in
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
            if !configured { configure() }
            if configured, !session.isRunning { session.startRunning() }
        }
    }

    func release() {
        users = max(users - 1, 0)
        guard users == 0 else { return }
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureVideoDataOutput()
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        configured = !session.inputs.isEmpty
    }
}

/// Adds the hardware key interaction to a plain UIView behind the screen.
@available(iOS 17.2, *)
private struct CaptureEventCatcher: UIViewRepresentable {
    let enabled: Bool
    let onEvent: (VolumeKey, VolumeKeyPhase) -> Void

    final class Coordinator {
        var onEvent: (VolumeKey, VolumeKeyPhase) -> Void = { _, _ in }
        var interaction: AVCaptureEventInteraction?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        let coordinator = context.coordinator
        // Primary is the volume-down button, secondary the volume-up button.
        let interaction = AVCaptureEventInteraction(
            primary: { event in coordinator.onEvent(.down, Self.phase(event.phase)) },
            secondary: { event in coordinator.onEvent(.up, Self.phase(event.phase)) }
        )
        view.addInteraction(interaction)
        coordinator.interaction = interaction
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onEvent = onEvent
        context.coordinator.interaction?.isEnabled = enabled
    }

    private static func phase(_ phase: AVCaptureEventPhase) -> VolumeKeyPhase {
        switch phase {
        case .began: return .began
        case .ended: return .ended
        default: return .cancelled
        }
    }
}

/// Volume keys drive the same session path as the on-screen hold area.
private struct VolumeKeyModifier: ViewModifier {
    let model: AppModel
    let enabled: Bool
    @State private var mapper = VolumeKeyMapper()

    func body(content: Content) -> some View {
        content
            .background {
                if #available(iOS 17.2, *) {
                    CaptureEventCatcher(enabled: enabled) { key, phase in
                        for action in mapper.actions(for: key, phase: phase) { model.send(action) }
                    }
                }
            }
            .onAppear { if enabled { CameraKeeper.shared.acquire() } }
            .onDisappear {
                if enabled { CameraKeeper.shared.release() }
                // Same rule as the hold area: leaving the screen ends the hold, a new press is needed.
                mapper = VolumeKeyMapper()
                if model.session.state.armMoving { model.send(.holdArmEnd) }
            }
    }
}

extension View {
    func volumeKeys(model: AppModel, enabled: Bool = true) -> some View {
        modifier(VolumeKeyModifier(model: model, enabled: enabled))
    }
}
