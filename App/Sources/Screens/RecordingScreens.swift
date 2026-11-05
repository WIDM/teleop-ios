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
                        Text(String(format: String(localized: "control.recording_time"), state.recordingTimeLabel))
                            .font(.system(size: 16, weight: .semibold))
                            .monospacedDigit()
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(minHeight: TeleopMetrics.touch)
                    .background(TeleopColors.recording, in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
                    .overlay(RoundedRectangle(cornerRadius: TeleopMetrics.corner).strokeBorder(.white, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("recording.stop")
                Button {} label: { Label("control.reset", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(OutlineButtonStyle())
                Button { model.send(.openSettings) } label: { Label("control.settings", systemImage: "gearshape") }
                    .buttonStyle(OutlineButtonStyle())
            }
            StopButton { model.send(.stop) }
        }
        .padding(TeleopMetrics.margin)
        .onAppear { model.send(.recordingAppeared) }
    }

    @ViewBuilder
    private func timerCard(_ state: FakeTeleopState) -> some View {
        let card = RoundedRectangle(cornerRadius: TeleopMetrics.corner)
            .fill(fallback ? TeleopColors.card : TeleopColors.camera)
            .overlay(alignment: .top) { GripperCard(gripper: state.gripper, fullWidth: true).padding(12) }
            .overlay {
                HStack(spacing: 12) {
                    Circle().fill(fallback ? TeleopColors.recording : Color.white).frame(width: 18, height: 18)
                    Text(state.recordingTimeLabel)
                        .font(.system(size: 72, weight: .semibold, design: .monospaced))
                        .accessibilityIdentifier("recording.timer")
                }
                .foregroundStyle(fallback ? TeleopColors.textPrimary : Color.white)
            }
            .overlay(alignment: .bottom) {
                if fallback {
                    Text("fallback.hold_hint")
                        .font(.system(size: 14))
                        .foregroundStyle(TeleopColors.textSecondary)
                        .padding(.bottom, 16)
                } else {
                    VolumeHintBox(textKey: "recording.volume_hint").padding(12)
                }
            }
        if fallback {
            card.armHold(model: model).accessibilityIdentifier("fallback.hold_recording")
        } else {
            card
        }
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
                .fill(TeleopColors.card)
                .overlay {
                    VStack(spacing: 12) {
                        Text(state.recordingTimeLabel)
                            .font(.system(size: 48, weight: .semibold, design: .monospaced))
                        Text("record.save_or_discard_hint")
                            .font(.system(size: 14))
                            .foregroundStyle(TeleopColors.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }
                }
            HStack(spacing: 8) {
                HoldButton(
                    titleKey: "record.discard_hold",
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

/// S3m: base handle held.
struct BaseTeleopScreen: View {
    let model: AppModel

    var body: some View {
        let state = model.session.state
        VStack(spacing: 12) {
            ControlStatusBar(
                modeKey: "control.base",
                connected: state.connected,
                heartbeatOk: state.heartbeatOk
            ) { model.send(.openConnection) }
            RoundedRectangle(cornerRadius: TeleopMetrics.corner)
                .fill(TeleopColors.camera)
                .overlay(alignment: .trailing) {
                    VStack {
                        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right").font(.system(size: 22))
                        Text("control.base").font(.system(size: 17))
                    }
                    .foregroundStyle(.white)
                    .frame(width: 72)
                    .frame(maxHeight: .infinity)
                    .background(
                        TeleopColors.primary,
                        in: UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12)
                    )
                    .padding(.vertical, 56)
                }
                .overlay(alignment: .top) { GripperCard(gripper: state.gripper).padding(.top, 12) }
                .overlay(alignment: .bottom) { VolumeHintBox(textKey: "base.volume_hint").padding(.bottom, 16) }
            HStack {
                Button { model.send(.openRecording) } label: { Text("control.record") }
                    .buttonStyle(TextActionStyle(color: TeleopColors.primary))
                Button { model.send(.releaseBase) } label: { Text("common.back") }
                    .buttonStyle(TextActionStyle())
                    .accessibilityIdentifier("base.release")
                Button { model.send(.openSettings) } label: { Text("control.settings") }
                    .buttonStyle(TextActionStyle())
            }
            StopButton { model.send(.stop) }
        }
        .padding(TeleopMetrics.margin)
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
            VStack(spacing: 8) {
                Image(systemName: "hand.tap").font(.system(size: 44))
                Text("fallback.hold_here").font(.system(size: 22, weight: .semibold))
                Text("fallback.hold_hint")
                    .font(.system(size: 12))
                    .foregroundStyle(TeleopColors.textSecondary)
                    .multilineTextAlignment(.center)
                Text(LocalizedStringKey(state.gripper == .open ? "control.gripper_open" : "control.gripper_closed"))
                    .font(.system(size: 14))
                    .padding(.top, 8)
            }
            .foregroundStyle(TeleopColors.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                TeleopColors.primary.opacity(state.armMoving ? 0.2 : 0.08),
                in: RoundedRectangle(cornerRadius: TeleopMetrics.corner)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TeleopMetrics.corner)
                    .strokeBorder(TeleopColors.primary.opacity(0.35), lineWidth: 1)
            )
            .armHold(model: model)
            .accessibilityIdentifier("fallback.hold")
            .padding(.top, 16)
            HStack(spacing: 8) {
                Button { model.send(.startFallbackRecording) } label: { Text("control.record") }
                    .buttonStyle(FilledButtonStyle())
                    .accessibilityIdentifier("fallback.record")
                Button { model.send(.toggleGripper) } label: { Text("control.gripper") }
                    .buttonStyle(OutlineButtonStyle())
                    .accessibilityIdentifier("fallback.toggle")
                Button { model.send(.openSettings) } label: { Text("control.settings") }
                    .buttonStyle(OutlineButtonStyle())
            }
            .padding(.vertical, 16)
            StopButton { model.send(.stop) }
        }
        .padding(TeleopMetrics.margin)
    }
}
