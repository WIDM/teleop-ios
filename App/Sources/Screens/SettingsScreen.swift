import SwiftUI
import TeleopCore

struct SettingsScreen: View {
    @Bindable var model: AppModel
    @State private var deadbandDegrees = 2.0
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
            VStack(alignment: .leading, spacing: 12) {
                sliderRow("settings.sensitivity", tag: "settings.gain_tag",
                          value: $model.session.state.sensitivity, range: 0...2,
                          label: String(format: "%.1f", model.session.state.sensitivity))
                sliderRow("settings.deadband", tag: "settings.deadband_tag",
                          value: $deadbandDegrees, range: 0...10,
                          label: String(format: "%.0f°", deadbandDegrees))
                sliderRow("settings.smoothing", tag: "settings.smoothing_tag",
                          value: $smoothing, range: 0...1,
                          label: String(format: "%.1f", smoothing))
            }
            .card()
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 4) {
                Text("settings.debug_log")
                Text(verbatim: "12:01:03 → pose_start seq 41")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(TeleopColors.textSecondary)
                Text(verbatim: "12:01:03 ← pose_stop_requested")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(TeleopColors.textSecondary)
                Text(verbatim: "12:01:03 ← pose_stopped")
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

    private func sliderRow(
        _ title: LocalizedStringKey, tag: LocalizedStringKey,
        value: Binding<Double>, range: ClosedRange<Double>, label: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 15))
                Text(tag).font(.system(size: 12)).foregroundStyle(TeleopColors.textSecondary)
                Spacer()
                Text(verbatim: label).font(.system(size: 15, design: .monospaced))
            }
            Slider(value: value, in: range)
        }
    }
}
