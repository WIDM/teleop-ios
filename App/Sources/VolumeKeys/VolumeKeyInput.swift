import AVKit
import SwiftUI
import TeleopCore

/// Adds the hardware key interaction to a plain UIView behind the screen. iOS sends the volume keys here only while
/// the camera is in use, which `PoseTracker` keeps it.
@available(iOS 17.2, *)
private struct CaptureEventCatcher: UIViewRepresentable {
    let enabled: Bool
    let onEvent: (InputKey, Bool) -> Void

    final class Coordinator {
        var onEvent: (InputKey, Bool) -> Void = { _, _ in }
        var interaction: AVCaptureEventInteraction?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        let coordinator = context.coordinator
        // Primary is the volume-down button, secondary the volume-up button. Cancelled counts as ended (§2.1).
        let interaction = AVCaptureEventInteraction(
            primary: { event in coordinator.onEvent(.lower, event.phase == .began) },
            secondary: { event in coordinator.onEvent(.upper, event.phase == .began) }
        )
        view.addInteraction(interaction)
        coordinator.interaction = interaction
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onEvent = onEvent
        context.coordinator.interaction?.isEnabled = enabled
    }
}

/// Hands the volume keys' raw began and ended events to the model, which judges them with the input rules.
private struct VolumeKeyModifier: ViewModifier {
    let model: AppModel
    let enabled: Bool

    func body(content: Content) -> some View {
        content
            .background {
                if #available(iOS 17.2, *) {
                    CaptureEventCatcher(enabled: enabled) { key, down in model.keyEvent(key, down: down) }
                }
            }
    }
}

extension View {
    func volumeKeys(model: AppModel, enabled: Bool = true) -> some View {
        modifier(VolumeKeyModifier(model: model, enabled: enabled))
    }
}
