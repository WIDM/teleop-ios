import SwiftUI

struct SettingsScreen: View {
    @Bindable var model: AppModel
    @State private var deadband = 0.2
    @State private var smoothing = 0.3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { model.send(.back) } label: { Text("common.back") }
                    .buttonStyle(TextActionStyle(color: TeleopColors.primary))
                    .accessibilityIdentifier("settings.back")
                Spacer()
                Text("control.settings").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button { model.send(.settingsDone) } label: { Text("common.done") }
                    .buttonStyle(TextActionStyle(color: TeleopColors.primary))
                    .accessibilityIdentifier("settings.done")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("settings.sensitivity")
                Slider(value: $model.session.state.sensitivity, in: 0.1...2)
                Text("settings.deadband")
                Slider(value: $deadband, in: 0...1)
                Text("settings.smoothing")
                Slider(value: $smoothing, in: 0...1)
            }
            .card()
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 4) {
                Text("settings.debug_log")
                Text(verbatim: "12:01:03 pose_start seq 41")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(TeleopColors.textSecondary)
                Text(verbatim: "12:01:03 pose_stop_requested")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(TeleopColors.textSecondary)
                HStack(spacing: 8) {
                    Button {} label: { Text("settings.send_hello") }.buttonStyle(OutlineButtonStyle())
                    Button {} label: { Text("settings.clear_log") }.buttonStyle(OutlineButtonStyle())
                }
                .padding(.top, 8)
            }
            .card()
            .padding(.top, 12)

            VStack(spacing: 0) {
                Button { model.send(.replayTutorial) } label: {
                    HStack {
                        Text("settings.replay_tutorial")
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(TeleopColors.chevronMuted)
                    }
                    .frame(minHeight: TeleopMetrics.touch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.replay_tutorial")
                Button { model.session.state.developerMode.toggle() } label: {
                    HStack {
                        Text("settings.developer_mode")
                        Spacer()
                        Text(LocalizedStringKey(model.session.state.developerMode ? "common.on" : "common.off"))
                            .foregroundStyle(TeleopColors.textSecondary)
                    }
                    .frame(minHeight: TeleopMetrics.touch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.developer_mode")
            }
            .padding(.horizontal, 16)
            .background(TeleopColors.card, in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
            .padding(.top, 12)

            Spacer()
            StopButton { model.send(.stop) }
        }
        .padding(TeleopMetrics.margin)
    }
}
