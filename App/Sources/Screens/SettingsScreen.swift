import SwiftUI
import TeleopCore

struct SettingsScreen: View {
    @Bindable var model: AppModel

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
            ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sliderRow("settings.sensitivity", tag: "settings.gain_tag",
                          value: $model.session.state.sensitivity, range: 0...2,
                          label: String(format: "%.1f", model.session.state.sensitivity))
                sliderRow("settings.deadband", tag: "settings.deadband_tag",
                          value: Binding(
                              get: { model.session.state.deadbandDegrees },
                              set: { model.session.state.setDeadband(degrees: $0) }
                          ),
                          range: FakeTeleopState.deadbandRange,
                          label: String(format: "%.0f°", model.session.state.deadbandDegrees))
                sliderRow("settings.smoothing", tag: "settings.smoothing_tag",
                          value: Binding(
                              get: { model.session.state.smoothing },
                              set: { model.session.state.setSmoothing($0) }
                          ),
                          range: FakeTeleopState.smoothingRange,
                          label: String(format: "%.1f", model.session.state.smoothing))
            }
            .card()
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("settings.language")
                    Spacer()
                    Picker("settings.language", selection: $model.language) {
                        ForEach(AppLanguage.allCases, id: \.self) { language in
                            if let name = language.nativeName {
                                Text(verbatim: name).tag(language)
                            } else {
                                Text("settings.language_system").tag(language)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("settings.language")
                }
                .frame(minHeight: TeleopMetrics.touch)
                Divider()
                Button { model.send(.switchMode) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("settings.switch_mode")
                            Text("settings.switch_mode_hint")
                                .font(.system(size: 12))
                                .foregroundStyle(TeleopColors.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(TeleopColors.chevronMuted)
                    }
                    .frame(minHeight: TeleopMetrics.touch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.switch_mode")
                Divider()
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
                Divider()
                Toggle(isOn: $model.liveLink) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.live_link")
                        Text("settings.live_link_hint")
                            .font(.system(size: 12))
                            .foregroundStyle(TeleopColors.textSecondary)
                    }
                }
                .frame(minHeight: TeleopMetrics.touch)
                .accessibilityIdentifier("settings.live_link")
                Divider()
                Toggle(isOn: $model.session.state.developerMode) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.developer_mode")
                        Text("settings.developer_hint")
                            .font(.system(size: 12))
                            .foregroundStyle(TeleopColors.textSecondary)
                    }
                }
                .frame(minHeight: TeleopMetrics.touch)
                .accessibilityIdentifier("settings.developer_mode")
            }
            .padding(.horizontal, 16)
            .background(TeleopColors.card, in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
            .padding(.top, 12)

            // Raw protocol lines stay out of the normal UI (S6 rule); developer mode shows them.
            if model.session.state.developerMode {
                VStack(alignment: .leading, spacing: 4) {
                    Text("settings.debug_log")
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                if model.debugLog.isEmpty {
                                    Text("settings.log_empty")
                                } else {
                                    ForEach(Array(model.debugLog.enumerated()), id: \.offset) { index, line in
                                        Text(verbatim: line).id(index)
                                    }
                                }
                            }
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(TeleopColors.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("settings.log")
                        }
                        .frame(height: 96)
                        .onChange(of: model.debugLog.count) { _, count in
                            if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                        }
                    }
                    Button { model.clearLog() } label: { Text("settings.clear_log") }
                        .buttonStyle(OutlineButtonStyle())
                        .accessibilityIdentifier("settings.clear_log")
                        .padding(.top, 8)
                }
                .card()
                .padding(.top, 12)
            }

            // Which version is on the phone: installs happen often, and the icon does not change.
            // CHANGELOG.md says what each version does.
            Text(String(format: L10n.string("settings.version"), Self.version))
                .font(.system(size: 12))
                .foregroundStyle(TeleopColors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                .accessibilityIdentifier("settings.version")
            }
            .scrollIndicators(.hidden)
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

    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
}
