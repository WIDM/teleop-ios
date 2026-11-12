import SwiftUI
import TeleopCore

/// Settings (§7.3), version 1 rows only, with a STOP band pinned to the bottom edge.
struct SettingsScreen: View {
    @Bindable var model: AppModel
    /// Five taps on the version show the developer log.
    @State private var versionTaps = 0

    /// Settings → Control → Smoothing: Off, Low and High (§7.3).
    static let smoothingSteps: [(key: LocalizedStringKey, value: Double)] = [
        ("settings.smoothing_off", 0), ("settings.smoothing_low", 0.3), ("settings.smoothing_high", 0.6),
    ]

    var body: some View {
        let practice = model.operating.practice
        VStack(spacing: 0) {
            PracticeBanner(practice: practice)
            if case .stopped = model.operating.state { stoppedBand }
            HStack {
                Text("settings.title").font(.system(size: 20, weight: .bold))
                Spacer()
                Button { model.send(.settingsDone) } label: { Text("common.done") }
                    .buttonStyle(TextActionStyle(color: TeleopColors.primary))
                    .accessibilityIdentifier("settings.done")
            }
            .padding(.horizontal, TeleopMetrics.margin)
            Form {
                control
                taskAid
                recording
                server
                practiceSection
                language
                about
                if versionTaps >= 5 { developer }
            }
            StopBand { model.send(.stop) }
        }
    }

    /// While the robot is stopped, Settings says so above everything and where the way out is, as the operating screen
    /// does: the stop is never hidden behind Settings.
    private var stoppedBand: some View {
        VStack(spacing: 2) {
            Text("state.stopped")
                .font(.system(size: 20, weight: .heavy))
            Text("settings.stopped")
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, TeleopMetrics.margin)
        .background(TeleopColors.stateRed.ignoresSafeArea(edges: .top))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.stopped")
    }

    private var control: some View {
        Section {
            Picker(selection: $model.controlMode) {
                ForEach(ControlMode.allCases, id: \.self) { mode in
                    Text(verbatim: OperatingWords.modeName(mode)).tag(mode)
                }
            } label: {
                Text("settings.mode")
            }
            .pickerStyle(.inline)
            .accessibilityIdentifier("settings.mode")
            VStack(alignment: .leading, spacing: 6) {
                Text("settings.hand")
                Picker(selection: $model.hand) {
                    Text("settings.hand_right").tag(Hand.right)
                    Text("settings.hand_left").tag(Hand.left)
                } label: {
                    Text("settings.hand")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("settings.hand")
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("settings.arm_speed")
                    Spacer()
                    Text(verbatim: String(format: "%g×", model.session.state.sensitivity))
                        .font(.system(size: 15, design: .monospaced))
                }
                Slider(value: $model.session.state.sensitivity, in: 0.5...2, step: 0.25)
                    .accessibilityLabel(Text("settings.arm_speed"))
                    .accessibilityValue(Text(verbatim: String(format: "%g×", model.session.state.sensitivity)))
                    .accessibilityIdentifier("settings.arm_speed")
                Text("settings.arm_speed_help")
                    .font(.system(size: 12))
                    .foregroundStyle(TeleopColors.textSecondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("settings.smoothing")
                Picker(selection: smoothing) {
                    ForEach(Self.smoothingSteps.indices, id: \.self) { index in
                        Text(Self.smoothingSteps[index].key).tag(index)
                    }
                } label: {
                    Text("settings.smoothing")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("settings.smoothing")
            }
        } header: {
            Text("settings.control")
        }
    }

    /// The step nearest the stored smoothing.
    private var smoothing: Binding<Int> {
        Binding(
            get: {
                let value = model.session.state.smoothing
                return Self.smoothingSteps.indices.min { abs(Self.smoothingSteps[$0].value - value) < abs(Self.smoothingSteps[$1].value - value) } ?? 1
            },
            set: { model.session.state.setSmoothing(Self.smoothingSteps[$0].value) }
        )
    }

    private var taskAid: some View {
        Section {
            Toggle(isOn: $model.taskAid) { Text("settings.task_aid_show") }
                .accessibilityIdentifier("settings.task_aid")
        } header: {
            Text("settings.task_aid")
        } footer: {
            Text("settings.task_aid_help")
        }
    }

    private var recording: some View {
        let display = model.operating
        return Section {
            Text(verbatim: OperatingWords.recLine(display)?.spoken ?? L10n.string("settings.rec_unknown"))
                .accessibilityIdentifier("settings.rec_status")
            if !display.practice, let saved = display.recorder.saved {
                LabeledContent { Text(verbatim: "\(saved)") } label: { Text("settings.rec_saved") }
            }
            if !display.practice, let discarded = display.recorder.discarded {
                LabeledContent { Text(verbatim: "\(discarded)") } label: { Text("settings.rec_discarded") }
            }
        } header: {
            Text("settings.recording")
        }
    }

    private var server: some View {
        let practice = model.operating.practice
        return Section {
            TextField(text: $model.session.state.serverAddress, prompt: Text(verbatim: "192.168.0.10:8765")) {
                Text("connection.server_address")
            }
            .font(.system(size: 16, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.numbersAndPunctuation)
            .accessibilityIdentifier("settings.address")
            if practice {
                // In practice Connect would only reconnect the demo, whatever the address says.
                Text("settings.practice_no_server")
                    .foregroundStyle(TeleopColors.textSecondary)
                    .accessibilityIdentifier("settings.server_practice")
            } else {
                HStack(spacing: 8) {
                    Button { model.connect() } label: { Text("connect.connect") }
                        .buttonStyle(FilledButtonStyle())
                        .accessibilityIdentifier("settings.connect")
                    Button {
                        // Disconnect goes back to Connect, with no error (§7.3).
                        model.send(.disconnect)
                        model.send(.changeServer)
                    } label: { Text("connect.disconnect") }
                        .buttonStyle(OutlineButtonStyle())
                        .accessibilityIdentifier("settings.disconnect")
                }
            }
        } header: {
            Text("settings.server")
        }
    }

    private var practiceSection: some View {
        // Practice cannot start or end while the stop is latched (AppModel.startPractice): say so.
        let stopped = model.session.state.emergencyStop
        return Section {
            if model.operating.practice {
                Button { model.leavePractice() } label: { Text("settings.leave_practice") }
                    .disabled(stopped)
                    .accessibilityIdentifier("settings.leave_practice")
            } else {
                Button { model.startPractice() } label: { Text("settings.start_practice") }
                    .disabled(stopped)
                    .accessibilityIdentifier("settings.start_practice")
            }
            if stopped {
                Text(model.practiceBlockedReason)
                    .foregroundStyle(TeleopColors.textSecondary)
                    .accessibilityIdentifier("settings.practice_stopped")
            }
        } header: {
            Text("settings.practice")
        }
    }

    private var language: some View {
        Section {
            Picker(selection: $model.language) {
                ForEach(AppLanguage.allCases, id: \.self) { language in
                    if let name = language.nativeName {
                        Text(verbatim: name).tag(language)
                    } else {
                        Text("settings.language_system").tag(language)
                    }
                }
            } label: {
                Text("settings.language")
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("settings.language")
        }
    }

    private var about: some View {
        Section {
            // Which version is on the phone: installs happen often, and the icon does not change.
            Text(verbatim: String(format: L10n.string("settings.version"), Self.version, Self.build))
                .foregroundStyle(TeleopColors.textSecondary)
                .contentShape(Rectangle())
                .onTapGesture { versionTaps += 1 }
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("settings.version")
        } header: {
            Text("settings.about")
        }
    }

    // Raw protocol lines stay out of the normal screens; five taps on the version show them.
    private var developer: some View {
        Section {
            if model.debugLog.isEmpty {
                Text("settings.log_empty")
                    .foregroundStyle(TeleopColors.textSecondary)
                    .accessibilityIdentifier("settings.log")
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.debugLog.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(TeleopColors.textSecondary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.log")
            }
            Button { model.clearLog() } label: { Text("settings.clear_log") }
                .accessibilityIdentifier("settings.clear_log")
        } header: {
            Text("settings.developer")
        }
    }

    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    private static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
}
