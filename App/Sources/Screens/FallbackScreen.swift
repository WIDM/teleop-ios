import SwiftUI
import TeleopCore

/// On-screen gripper controls for the fallback screen, where there are no volume keys.
private struct GripperHoldRow: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            GripperHoldButton(model: model, target: .closed)
            GripperHoldButton(model: model, target: .open)
        }
    }
}

/// Pale blue press area of S5. The screen attaches the hold gesture.
private struct HoldPad: View {
    let gripper: GripperState
    let armMoving: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "hand.tap").font(.system(size: 44))
            Text("fallback.hold_here").font(.system(size: 22, weight: .semibold))
            Text("fallback.hold_hint")
                .font(.system(size: 12))
                .foregroundStyle(TeleopColors.textSecondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 2) {
                Text(LocalizedStringKey(gripper == .open ? "control.gripper_open" : "control.gripper_closed"))
                Text("fallback.only_when_unavailable")
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
        // One element, so the id, value and traits the screen attaches land on the press area, not its children.
        .accessibilityElement(children: .combine)
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
                connected: state.connected
            ) { model.send(.openConnection) }
            HoldPad(gripper: state.gripper, armMoving: state.armMoving)
                .armHold(model: model)
                .accessibilityIdentifier("fallback.hold")
                .padding(.top, 16)
            Button { model.send(.openSettings) } label: { Text("control.settings") }
                .buttonStyle(OutlineButtonStyle())
                .padding(.top, 16)
            GripperHoldRow(model: model)
                .padding(.vertical, 8)
            StopButton { model.send(.stop) }
        }
        .padding(TeleopMetrics.margin)
    }
}
