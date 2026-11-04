import SwiftUI
import TeleopCore

/// P4 and P6 (high latency). No latency number here; it lives on P5 and P7.
struct StandbyScreen: View {
    let model: AppModel
    var highLatency = false
    var showStop = true

    var body: some View {
        let state = model.session.state
        let blocked = highLatency || state.commandsBlocked
        VStack(spacing: 8) {
            ControlStatusBar(
                modeKey: "control.standby",
                connected: state.connected,
                amber: blocked,
                heartbeatOk: state.heartbeatOk
            ) { model.send(.openConnection) }

            RoundedRectangle(cornerRadius: TeleopMetrics.corner)
                .fill(TeleopColors.camera)
                .overlay(alignment: .top) { gripperCard(state).padding(.top, 12) }
                .overlay {
                    VStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 40, weight: .light))
                        Text("control.gripper_aim").font(.system(size: 14))
                    }
                    .foregroundStyle(.white)
                }
                .overlay(alignment: .bottom) { volumeHint.padding(.bottom, 16) }
                .overlay(alignment: .trailing) {
                    BaseHandle { model.send(.openBase) }
                        .frame(width: 72)
                        .padding(.vertical, 56)
                }
                .overlay {
                    if blocked {
                        Text("connection.blocked_banner")
                            .font(.system(size: 14, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(TeleopColors.statusAmber, in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
                            .padding(.horizontal, 24)
                            .accessibilityIdentifier("standby.blocked_banner")
                    }
                }

            HStack {
                RecordButton(isRecording: state.isRecording, elapsed: state.recordingTimeLabel) {
                    model.send(.openRecording)
                }
                Button {} label: { Label("control.reset", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(TextActionStyle())
                Button { model.send(.openSettings) } label: { Label("control.settings", systemImage: "gearshape") }
                    .buttonStyle(TextActionStyle())
                    .accessibilityIdentifier("standby.settings")
            }
            .frame(maxWidth: .infinity)

            if !highLatency {
                Button { model.send(.simulateHighLatency) } label: { Text("demo.simulate_high_latency") }
                    .buttonStyle(TextActionStyle(color: TeleopColors.textSecondary))
                    .accessibilityIdentifier("standby.simulate_high_latency")
            } else {
                Button { model.send(.simulateNormalLatency) } label: { Text("demo.simulate_normal_latency") }
                    .buttonStyle(TextActionStyle(color: TeleopColors.textSecondary))
                    .accessibilityIdentifier("standby.simulate_normal_latency")
            }
            Button { model.send(.openFallback) } label: { Text("fallback.title") }
                .buttonStyle(TextActionStyle(color: TeleopColors.textSecondary))
                .accessibilityIdentifier("standby.fallback")

            if showStop {
                StopButton { model.send(.stop) }
            }
        }
        .padding(.horizontal, TeleopMetrics.margin)
        .padding(.vertical, 12)
    }

    private func gripperCard(_ state: FakeTeleopState) -> some View {
        VStack(spacing: 2) {
            Text(LocalizedStringKey(state.gripper == .open ? "control.gripper_open" : "control.gripper_closed"))
                .font(.system(size: 20, weight: .semibold))
            Text("control.gripper_pulse_hint")
                .font(.system(size: 14))
                .foregroundStyle(TeleopColors.textSecondary)
        }
        .foregroundStyle(TeleopColors.textPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(TeleopColors.card.opacity(0.92), in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
    }

    private var volumeHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill")
            Text("control.volume_hint").font(.system(size: 13))
        }
        .foregroundStyle(TeleopColors.textSecondary)
        .padding(12)
        .background(TeleopColors.card.opacity(0.92), in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
    }
}

struct BaseHandle: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right").font(.system(size: 22))
                Text("control.base").font(.system(size: 17))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                TeleopColors.basePanel,
                in: UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("standby.base")
    }
}

struct RecordButton: View {
    let isRecording: Bool
    let elapsed: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isRecording {
                HStack(spacing: 8) {
                    BlinkingDot()
                    Text(String(format: String(localized: "control.recording_time"), elapsed))
                        .font(.system(size: 16, weight: .semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(minHeight: TeleopMetrics.touch)
                .background(TeleopColors.recording, in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
                .overlay(
                    RoundedRectangle(cornerRadius: TeleopMetrics.corner).strokeBorder(.white, lineWidth: 2)
                )
            } else {
                Label("control.record", systemImage: "circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(TeleopColors.primary)
                    .padding(.horizontal, 14)
                    .frame(minHeight: TeleopMetrics.touch)
                    .background(TeleopColors.card, in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
                    .overlay(
                        RoundedRectangle(cornerRadius: TeleopMetrics.corner)
                            .strokeBorder(TeleopColors.primary, lineWidth: 2)
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("standby.record")
    }
}
