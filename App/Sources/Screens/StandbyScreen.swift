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
                .overlay(alignment: .top) { GripperCard(gripper: state.gripper).padding(.top, 12) }
                .overlay { AimOrOffset(model: model) }
                .overlay(alignment: .bottom) {
                    VolumeHintBox(textKey: "control.volume_hint") { model.send(.openFallback) }.padding(.bottom, 16)
                }
                .overlay(alignment: .leading) {
                    // Lower than centre: the latency banner sits across the top of the view.
                    LeftHandles(model: model)
                        .frame(width: 72)
                        .padding(.top, 170)
                        .padding(.bottom, 130)
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
                Button { model.send(.resetScene) } label: { Label("control.reset", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(OutlineButtonStyle())
                    .accessibilityIdentifier("standby.reset")
                Button { model.send(.openSettings) } label: { Label("control.settings", systemImage: "gearshape") }
                    .buttonStyle(OutlineButtonStyle())
                    .accessibilityIdentifier("standby.settings")
            }

            if showStop {
                StopButton { model.send(.stop) }
            }
        }
        .padding(.horizontal, TeleopMetrics.margin)
        .padding(.vertical, 12)
        .volumeKeys(model: model, enabled: showStop)
    }
}
