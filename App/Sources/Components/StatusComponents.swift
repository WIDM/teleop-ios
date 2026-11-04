import SwiftUI

struct ConnectionChip: View {
    var connected: Bool
    var amber = false
    var heartbeatOk = true
    var lost = false
    var onTap: (() -> Void)? = nil

    private var effectivelyConnected: Bool { connected && heartbeatOk }

    private var dotColor: Color {
        if lost { return TeleopColors.emergency }
        if !effectivelyConnected { return TeleopColors.textSecondary }
        return amber ? TeleopColors.statusAmber : TeleopColors.statusGreen
    }

    private var labelKey: LocalizedStringKey {
        if lost { return "status.disconnected" }
        return effectivelyConnected ? "status.connected" : "status.not_connected"
    }

    var body: some View {
        let content = HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 10, height: 10)
            Text(labelKey)
                .font(.system(size: 14))
                .foregroundStyle(TeleopColors.textPrimary)
            if onTap != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TeleopColors.textSecondary)
            }
        }
        .frame(minHeight: TeleopMetrics.touch)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())

        if let onTap {
            Button(action: onTap) { content }
                .buttonStyle(.plain)
                .accessibilityIdentifier("status.chip")
        } else {
            content
        }
    }
}

struct ModePill: View {
    let textKey: LocalizedStringKey

    var body: some View {
        Text(textKey)
            .font(.system(size: 14))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(TeleopColors.primary, in: Capsule())
    }
}

struct ControlStatusBar: View {
    let modeKey: LocalizedStringKey
    var connected: Bool
    var amber = false
    var heartbeatOk = true
    let onConnectionTap: () -> Void

    var body: some View {
        HStack {
            ModePill(textKey: modeKey)
            Spacer()
            ConnectionChip(connected: connected, amber: amber, heartbeatOk: heartbeatOk, onTap: onConnectionTap)
        }
        .frame(minHeight: TeleopMetrics.touch)
        .padding(.horizontal, 8)
        .background(TeleopColors.card, in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
    }
}

struct BlinkingDot: View {
    var color: Color = .white
    var size: CGFloat = 8
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(dim ? 0.15 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

extension View {
    func card(border: Color? = nil) -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TeleopColors.card, in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
            .overlay(
                RoundedRectangle(cornerRadius: TeleopMetrics.corner)
                    .strokeBorder(border ?? .clear, lineWidth: 2)
            )
    }
}

struct ServerAddressField: View {
    let address: String
    let error: Bool

    var body: some View {
        Text(address)
            .font(.system(size: 16, design: .monospaced))
            .foregroundStyle(TeleopColors.textPrimary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: TeleopMetrics.touch, alignment: .leading)
            .background(
                (error ? TeleopColors.statusAmber.opacity(0.15) : TeleopColors.textSecondary.opacity(0.08)),
                in: RoundedRectangle(cornerRadius: TeleopMetrics.corner)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TeleopMetrics.corner)
                    .strokeBorder(error ? TeleopColors.statusAmber : .clear, lineWidth: 2)
            )
    }
}
