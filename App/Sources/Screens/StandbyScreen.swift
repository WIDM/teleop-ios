import SwiftUI
import TeleopCore

/// P4 and P6 (high latency). No latency number here; it lives on P5 and P7.
/// The prototype shortcuts (simulate latency, on-screen controls) are not in Figma; they live in a
/// debug sheet opened by holding the mode pill for 1 second.
struct StandbyScreen: View {
    let model: AppModel
    var highLatency = false
    var showStop = true
    @State private var showDebug = false

    var body: some View {
        let state = model.session.state
        let blocked = highLatency || state.commandsBlocked
        let openDebug: (() -> Void)? = showStop ? { showDebug = true } : nil
        VStack(spacing: 8) {
            ControlStatusBar(
                modeKey: "control.standby",
                connected: state.connected,
                amber: blocked,
                heartbeatOk: state.heartbeatOk,
                onModeLongPress: openDebug
            ) { model.send(.openConnection) }

            RoundedRectangle(cornerRadius: TeleopMetrics.corner)
                .fill(TeleopColors.camera)
                .overlay(alignment: .top) { GripperCard(gripper: state.gripper).padding(.top, 12) }
                .overlay {
                    VStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 40, weight: .light))
                        Text("control.gripper_aim").font(.system(size: 14))
                    }
                    .foregroundStyle(.white)
                }
                .overlay(alignment: .bottom) { VolumeHintBox(textKey: "control.volume_hint").padding(.bottom, 16) }
                .overlay(alignment: .trailing) {
                    BaseHandle { model.send(.openBase) }
                        .frame(width: 72)
                        .padding(.vertical, 56)
                }
                .overlay(alignment: .top) {
                    if blocked {
                        Text("connection.blocked_banner")
                            .font(.system(size: 14, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity)
                            .background(TeleopColors.statusAmber, in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
                            .padding(.horizontal, 16)
                            .padding(.top, 118)
                            .accessibilityIdentifier("standby.blocked_banner")
                    }
                }

            HStack(spacing: 8) {
                RecordButton(isRecording: state.isRecording, elapsed: state.recordingTimeLabel) {
                    model.send(.openRecording)
                }
                Button {} label: { Label("control.reset", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(OutlineButtonStyle())
                Button { model.send(.openSettings) } label: { Label("control.settings", systemImage: "gearshape") }
                    .buttonStyle(OutlineButtonStyle())
                    .accessibilityIdentifier("standby.settings")
            }

            if showStop && !showDebug {
                StopButton { model.send(.stop) }
            }
        }
        .padding(.horizontal, TeleopMetrics.margin)
        .padding(.vertical, 12)
        .sheet(isPresented: $showDebug) { debugSheet }
    }

    private var debugSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("debug.title").font(.system(size: 20, weight: .semibold))
            Text("debug.hint")
                .font(.system(size: 14))
                .foregroundStyle(TeleopColors.textSecondary)
            if highLatency {
                debugButton("demo.simulate_normal_latency", id: "standby.simulate_normal_latency", .simulateNormalLatency)
            } else {
                debugButton("demo.simulate_high_latency", id: "standby.simulate_high_latency", .simulateHighLatency)
            }
            debugButton("fallback.title", id: "standby.fallback", .openFallback)
            Spacer()
            StopButton(accessibilityId: "stop.debug") {
                showDebug = false
                model.send(.stop)
            }
        }
        .padding(20)
        .presentationDetents([.height(280 + TeleopMetrics.stopHeight)])
    }

    private func debugButton(_ title: LocalizedStringKey, id: String, _ action: TeleopAction) -> some View {
        Button {
            showDebug = false
            model.send(action)
        } label: { Text(title) }
            .buttonStyle(OutlineButtonStyle())
            .accessibilityIdentifier(id)
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
                .frame(maxWidth: .infinity, minHeight: TeleopMetrics.touch)
                .background(TeleopColors.recording, in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
                .overlay(
                    RoundedRectangle(cornerRadius: TeleopMetrics.corner).strokeBorder(.white, lineWidth: 2)
                )
            } else {
                Label("control.record", systemImage: "circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(TeleopColors.primary)
                    .frame(maxWidth: .infinity, minHeight: TeleopMetrics.touch)
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
