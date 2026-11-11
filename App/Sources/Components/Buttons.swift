import SwiftUI
import TeleopCore

/// The red STOP band pinned to the bottom of every screen that is not the operating screen (§2.8). It acts on
/// touch-down, as the operating screen's band does: a stop must not wait for the finger to lift.
struct StopBand: View {
    let action: () -> Void
    @State private var down = false

    var body: some View {
        Text("band.stop")
            .font(.system(size: 26, weight: .heavy))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: TeleopMetrics.stopHeight)
            .background(TeleopColors.emergency.ignoresSafeArea(edges: .bottom))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !down else { return }
                        down = true
                        action()
                    }
                    .onEnded { _ in down = false }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("band.stop"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
            .accessibilityIdentifier("stop")
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
            Text(titleKey)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
