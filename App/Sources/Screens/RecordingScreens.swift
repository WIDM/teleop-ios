import SwiftUI
import TeleopCore

/// S3a, and S5a when `fallback` is set. S5a is the hold pad too: press moves the arm, release stops.
struct RecordingScreen: View {
    let model: AppModel
    let fallback: Bool

    var body: some View {
        let state = model.session.state
        VStack(spacing: 12) {
            ControlStatusBar(
                modeKey: "control.recording",
                connected: state.connected,
                heartbeatOk: state.heartbeatOk,
                recording: true
            ) { model.send(.openConnection) }
            timerCard(state)
            HStack(spacing: 8) {
                Button { model.send(.stopRecording) } label: {
                    HStack(spacing: 8) {
                        BlinkingDot()
                        Text(String(format: L10n.string("control.recording_time"), state.recordingTimeLabel))
                            .font(.system(size: 16, weight: .semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(minHeight: TeleopMetrics.touch)
                    .background(TeleopColors.recording, in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
                    .overlay(RoundedRectangle(cornerRadius: TeleopMetrics.corner).strokeBorder(.white, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("recording.stop")
                if !fallback {
                    Button { model.send(.resetScene) } label: { compactLabel("control.reset", systemImage: "arrow.counterclockwise") }
                        .buttonStyle(OutlineButtonStyle())
                        .accessibilityIdentifier("recording.reset")
                }
                Button { model.send(.openSettings) } label: { compactLabel("control.settings", systemImage: "gearshape") }
                    .buttonStyle(OutlineButtonStyle())
            }
            if fallback { GripperHoldRow(model: model) }
            StopButton { model.send(.stop) }
        }
        .padding(TeleopMetrics.margin)
        .volumeKeys(model: model)
        .onAppear { model.send(.recordingAppeared) }
    }

    /// The recording button takes most of this row, so its neighbours use a smaller label.
    private func compactLabel(_ titleKey: LocalizedStringKey, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(titleKey)
        }
        .font(.system(size: 14, weight: .semibold))
        .lineLimit(1)
    }

    @ViewBuilder
    private func timerCard(_ state: FakeTeleopState) -> some View {
        if fallback {
            HoldPad(gripper: state.gripper, armMoving: state.armMoving, captionKey: "fallback.stop_recording_hint") {
                HStack(spacing: 12) {
                    Circle().fill(TeleopColors.recording).frame(width: 18, height: 18)
                    Text(state.recordingTimeLabel)
                        .font(.system(size: 48, weight: .semibold, design: .monospaced))
                        .accessibilityIdentifier("recording.timer")
                }
                .foregroundStyle(TeleopColors.textPrimary)
            }
            .armHold(model: model)
            .accessibilityIdentifier("fallback.hold_recording")
        } else {
            RoundedRectangle(cornerRadius: TeleopMetrics.corner)
                .fill(TeleopColors.camera)
                .overlay(alignment: .top) { GripperCard(gripper: state.gripper, fullWidth: true).padding(12) }
                .overlay {
                    HStack(spacing: 12) {
                        Circle().fill(Color.white).frame(width: 18, height: 18)
                        Text(state.recordingTimeLabel)
                            .font(.system(size: 72, weight: .semibold, design: .monospaced))
                            .accessibilityIdentifier("recording.timer")
                    }
                    .foregroundStyle(Color.white)
                }
                .overlay(alignment: .bottom) { VolumeHintBox(textKey: "recording.volume_hint").padding(12) }
                .overlay(alignment: .leading) {
                    // Lower than centre: the latency banner sits across the top of the view.
                    LeftHandles(model: model)
                        .frame(width: 72)
                        .padding(.top, 170)
                        .padding(.bottom, 130)
                }
        }
    }
}

/// On-screen gripper controls for the fallback screens, where there are no volume keys.
private struct GripperHoldRow: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            GripperHoldButton(model: model, target: .closed)
            GripperHoldButton(model: model, target: .open)
        }
    }
}

/// Pale blue press area shared by S5 and S5a. The screens attach the hold gesture.
private struct HoldPad<Header: View>: View {
    let gripper: GripperState
    let armMoving: Bool
    let captionKey: LocalizedStringKey
    @ViewBuilder let header: () -> Header

    var body: some View {
        VStack(spacing: 8) {
            header()
            Image(systemName: "hand.tap").font(.system(size: 44))
            Text("fallback.hold_here").font(.system(size: 22, weight: .semibold))
            Text("fallback.hold_hint")
                .font(.system(size: 12))
                .foregroundStyle(TeleopColors.textSecondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 2) {
                Text(LocalizedStringKey(gripper == .open ? "control.gripper_open" : "control.gripper_closed"))
                Text(captionKey)
            }
            .font(.system(size: 12))
            .foregroundStyle(TeleopColors.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.top, 4)
        }
        .foregroundStyle(TeleopColors.primary)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            TeleopColors.primary.opacity(armMoving ? 0.2 : 0.08),
            in: RoundedRectangle(cornerRadius: TeleopMetrics.corner)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TeleopMetrics.corner)
                .strokeBorder(TeleopColors.primary.opacity(0.35), lineWidth: 1)
        )
        // One element, so the id, value and traits the screens attach land on the press area, not its children.
        .accessibilityElement(children: .combine)
    }
}

/// S3b: save or discard (discard needs a 1 second hold).
struct RecordEndScreen: View {
    let model: AppModel

    var body: some View {
        let state = model.session.state
        VStack(spacing: 12) {
            ControlStatusBar(
                modeKey: "control.standby",
                connected: state.connected,
                heartbeatOk: state.heartbeatOk
            ) { model.send(.openConnection) }
            RoundedRectangle(cornerRadius: TeleopMetrics.corner)
                .fill(TeleopColors.camera)
                .overlay(alignment: .top) { GripperCard(gripper: state.gripper, fullWidth: true).padding(12) }
                .overlay {
                    Text(state.recordingTimeLabel)
                        .font(.system(size: 72, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white)
                }
                .overlay(alignment: .bottom) { VolumeHintBox(textKey: "record.save_or_discard_hint").padding(12) }
            HStack(spacing: 8) {
                HoldButton(
                    titleKey: "record.discard_hold",
                    systemImage: "trash",
                    fill: TeleopColors.card,
                    border: TeleopColors.statusAmber,
                    foreground: TeleopColors.textPrimary
                ) { model.send(.discardRecording) }
                .accessibilityIdentifier("record.discard")
                Button { model.send(.saveRecording) } label: {
                    Label("record.save", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(FilledButtonStyle(color: TeleopColors.statusGreen))
                .accessibilityIdentifier("record.save")
            }
            StopButton { model.send(.stop) }
        }
        .padding(TeleopMetrics.margin)
    }
}

/// S3m: base handle held. Tapping the handle again releases it.
struct BaseTeleopScreen: View {
    let model: AppModel

    var body: some View {
        let state = model.session.state
        VStack(spacing: 12) {
            ControlStatusBar(
                modeKey: "control.standby",
                connected: state.connected,
                heartbeatOk: state.heartbeatOk
            ) { model.send(.openConnection) }
            RoundedRectangle(cornerRadius: TeleopMetrics.corner)
                .fill(TeleopColors.camera)
                // Same centre as standby, so entering base mode does not look like a toggle.
                .overlay { AimOrOffset(model: model) }
                .overlay(alignment: .trailing) {
                    BaseHandle(accessibilityId: "base.release") { model.send(.releaseBase) }
                        .frame(width: 72)
                        .padding(.vertical, 56)
                }
                .overlay(alignment: .leading) {
                    // Lower than centre: the latency banner sits across the top of the view.
                    LeftHandles(model: model)
                        .frame(width: 72)
                        .padding(.top, 170)
                        .padding(.bottom, 130)
                }
                .overlay(alignment: .top) { GripperCard(gripper: state.gripper).padding(.top, 12) }
                .overlay(alignment: .bottom) { VolumeHintBox(textKey: "base.volume_hint").padding(.bottom, 16) }
            HStack(spacing: 8) {
                RecordButton(isRecording: state.isRecording, elapsed: state.recordingTimeLabel) {
                    model.send(.openRecording)
                }
                Button { model.send(.resetScene) } label: { Label("control.reset", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(OutlineButtonStyle())
                    .accessibilityIdentifier("base.reset")
                Button { model.send(.openSettings) } label: { Label("control.settings", systemImage: "gearshape") }
                    .buttonStyle(OutlineButtonStyle())
            }
            StopButton { model.send(.stop) }
        }
        .padding(TeleopMetrics.margin)
        .volumeKeys(model: model)
    }
}

/// S5: on-screen controls when volume keys are unavailable.
struct FallbackControlScreen: View {
    let model: AppModel

    var body: some View {
        let state = model.session.state
        VStack(alignment: .leading, spacing: 0) {
            ControlStatusBar(
                modeKey: "control.standby",
                connected: state.connected,
                heartbeatOk: state.heartbeatOk
            ) { model.send(.openConnection) }
            HoldPad(gripper: state.gripper, armMoving: state.armMoving, captionKey: "fallback.only_when_unavailable") {
                EmptyView()
            }
            .armHold(model: model)
            .accessibilityIdentifier("fallback.hold")
            .padding(.top, 16)
            HStack(spacing: 8) {
                Button { model.send(.startFallbackRecording) } label: { Text("control.record") }
                    .buttonStyle(FilledButtonStyle())
                    .accessibilityIdentifier("fallback.record")
                Button { model.send(.openSettings) } label: { Text("control.settings") }
                    .buttonStyle(OutlineButtonStyle())
            }
            .padding(.top, 16)
            GripperHoldRow(model: model)
                .padding(.vertical, 8)
            StopButton { model.send(.stop) }
        }
        .padding(TeleopMetrics.margin)
    }
}
