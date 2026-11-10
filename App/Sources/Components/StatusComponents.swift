import SwiftUI
import TeleopCore

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
    var color: Color = TeleopColors.primary
    var showsDot = false

    var body: some View {
        HStack(spacing: 6) {
            if showsDot { Circle().fill(.white).frame(width: 10, height: 10) }
            Text(textKey).font(.system(size: 14))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(color, in: Capsule())
    }
}

struct ControlStatusBar: View {
    let modeKey: LocalizedStringKey
    var connected: Bool
    var amber = false
    var heartbeatOk = true
    var recording = false
    var onModeLongPress: (() -> Void)? = nil
    let onConnectionTap: () -> Void

    var body: some View {
        HStack {
            pill
            Spacer()
            ConnectionChip(connected: connected, amber: amber, heartbeatOk: heartbeatOk, onTap: onConnectionTap)
        }
        .frame(minHeight: TeleopMetrics.touch)
        .padding(.horizontal, 8)
        .background(TeleopColors.card, in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
    }

    @ViewBuilder
    private var pill: some View {
        let base = ModePill(
            textKey: modeKey,
            color: recording ? TeleopColors.recording : TeleopColors.primary,
            showsDot: recording
        )
        if let onModeLongPress {
            base
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 1, perform: onModeLongPress)
                .accessibilityIdentifier("status.mode_pill")
        } else {
            base
        }
    }
}

struct GripperCard: View {
    let gripper: GripperState
    var fullWidth = false

    var body: some View {
        VStack(spacing: 2) {
            Text(LocalizedStringKey(gripper == .open ? "control.gripper_open" : "control.gripper_closed"))
                .font(.system(size: 20, weight: .semibold))
            Text("control.gripper_pulse_hint")
                .font(.system(size: 14))
                .foregroundStyle(TeleopColors.textSecondary)
        }
        .foregroundStyle(TeleopColors.textPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: fullWidth ? .infinity : nil)
        .background(TeleopColors.gripperCard, in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
    }
}

struct VolumeHintBox: View {
    let textKey: LocalizedStringKey
    var onTap: (() -> Void)? = nil

    var body: some View {
        if let onTap {
            Button(action: onTap) { content }
                .buttonStyle(.plain)
                .accessibilityIdentifier("volume_hint")
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill")
            Text(textKey)
                .font(.system(size: 13))
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(TeleopColors.textSecondary)
        .padding(12)
        .background(TeleopColors.card.opacity(0.92), in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
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

/// Centre of the camera view. Idle: the crosshair and its label. During a live arm hold: how far the arm
/// is being asked to move, so the operator can see which way the phone is taking it.
struct AimOrOffset: View {
    let model: AppModel

    var body: some View {
        if let offset = model.holdOffset {
            VStack(alignment: .leading, spacing: 6) {
                row(offset.x, positive: "control.dir_right", negative: "control.dir_left")
                row(offset.y, positive: "control.dir_forward", negative: "control.dir_back")
                row(offset.z, positive: "control.dir_up", negative: "control.dir_down")
                if model.catchingUp {
                    Text("control.catching_up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TeleopColors.statusAmber)
                        .accessibilityIdentifier("control.catching_up")
                }
            }
            .foregroundStyle(.white)
            .accessibilityIdentifier("control.offset")
        } else {
            VStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 40, weight: .light))
                Text("control.gripper_aim").font(.system(size: 14))
            }
            .foregroundStyle(.white)
        }
    }

    private func row(_ meters: Float, positive: LocalizedStringKey, negative: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Text(meters >= 0 ? positive : negative)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, alignment: .leading)
            Text(String(format: "%.1f cm", abs(meters) * 100))
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
        }
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
