import SwiftUI

struct StopButton: View {
    var accessibilityId = "stop"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                Text("stop.label").font(.system(size: 22, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: TeleopMetrics.stopHeight)
            .background(TeleopColors.emergency, in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
            .overlay(
                RoundedRectangle(cornerRadius: TeleopMetrics.corner)
                    .strokeBorder(TeleopColors.emergencyBorder, lineWidth: 3)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityId)
    }
}

struct FilledButtonStyle: ButtonStyle {
    var color: Color = TeleopColors.primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: TeleopMetrics.touch)
            .background(color, in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct OutlineButtonStyle: ButtonStyle {
    var color: Color = TeleopColors.textPrimary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, minHeight: TeleopMetrics.touch)
            .background(TeleopColors.card, in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
            .overlay(
                RoundedRectangle(cornerRadius: TeleopMetrics.corner)
                    .strokeBorder(color.opacity(0.4), lineWidth: 1.5)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct TextActionStyle: ButtonStyle {
    var color: Color = TeleopColors.textPrimary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16))
            .foregroundStyle(color)
            .frame(minHeight: TeleopMetrics.touch)
            .padding(.horizontal, 8)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Needs a 1 second press, with a bar that fills while held.
struct HoldButton: View {
    let titleKey: LocalizedStringKey
    var systemImage: String? = nil
    var fill: Color = TeleopColors.emergency
    var border: Color? = nil
    var borderWidth: CGFloat = 3
    var foreground: Color = .white
    var progress: Color = Color.white.opacity(0.35)
    var height: CGFloat = TeleopMetrics.touch
    let action: () -> Void

    @GestureState private var pressing = false

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: TeleopMetrics.corner).fill(fill)
            GeometryReader { proxy in
                Rectangle()
                    .fill(progress)
                    .frame(width: proxy.size.width * (pressing ? 1 : 0))
                    .animation(pressing ? .linear(duration: 1) : .easeOut(duration: 0.15), value: pressing)
            }
            .clipShape(RoundedRectangle(cornerRadius: TeleopMetrics.corner))
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(titleKey).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
        }
        .frame(height: height)
        .overlay(
            RoundedRectangle(cornerRadius: TeleopMetrics.corner)
                .strokeBorder(border ?? .clear, lineWidth: borderWidth)
        )
        .contentShape(RoundedRectangle(cornerRadius: TeleopMetrics.corner))
        .gesture(
            LongPressGesture(minimumDuration: 1)
                .updating($pressing) { value, state, _ in state = value }
                .onEnded { _ in action() }
        )
        .accessibilityAddTraits(.isButton)
    }
}

/// Press = start moving the arm, release = stop. Same session path as holding vol+ (`holdArmStart` / `holdArmEnd`).
/// One press sends one `holdArmStart`, so finger drift cannot repeat a blocked cue or restart an arm that was auto-stopped.
/// `@GestureState` also resets when the system cancels the gesture (call, Control Center), so that sends `holdArmEnd` too.
private struct ArmHoldModifier: ViewModifier {
    let model: AppModel
    @GestureState private var pressing = false
    @State private var startSent = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressing) { _, state, _ in state = true }
                    .onChanged { _ in
                        guard !startSent else { return }
                        startSent = true
                        model.send(.holdArmStart)
                    }
                    .onEnded { _ in
                        startSent = false
                        model.send(.holdArmEnd)
                    }
            )
            .onChange(of: pressing) { _, isPressing in
                guard !isPressing else { return }
                startSent = false
                model.send(.holdArmEnd)
            }
            .onDisappear {
                guard model.session.state.armMoving else { return }
                model.send(.holdArmEnd)
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(model.session.state.armMoving ? "moving" : "stopped")
    }
}

extension View {
    func armHold(model: AppModel) -> some View {
        modifier(ArmHoldModifier(model: model))
    }
}
