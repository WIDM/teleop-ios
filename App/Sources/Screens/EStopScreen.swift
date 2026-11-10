import SwiftUI
import TeleopCore

/// S4: emergency stop active. Release needs a 1 second hold.
struct EStopScreen: View {
    let model: AppModel

    var body: some View {
        let state = model.session.state
        VStack(spacing: 0) {
            HStack {
                Text("stop.active")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(TeleopColors.emergency, in: Capsule())
                Spacer()
                ConnectionChip(connected: state.connected, heartbeatOk: state.heartbeatOk) { model.send(.openConnection) }
            }
            .frame(minHeight: TeleopMetrics.touch)
            .padding(.horizontal, 8)
            .background(TeleopColors.card, in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
            VStack(spacing: 6) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 44))
                Text("stop.active")
                    .font(.system(size: 32, weight: .bold))
                Text("stop.locked")
                    .font(.system(size: 16))
                    .foregroundStyle(TeleopColors.textPrimary)
                Text("stop.inputs_ignored")
                    .font(.system(size: 14))
                    .foregroundStyle(TeleopColors.textSecondary)
                if let cause = model.stopCause {
                    Text(cause.text)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TeleopColors.textPrimary)
                        .padding(.top, 6)
                        .padding(.horizontal, 12)
                        .accessibilityIdentifier("stop.cause")
                }
            }
            .foregroundStyle(TeleopColors.emergency)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .background(TeleopColors.emergency.opacity(0.08), in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
            .overlay(
                RoundedRectangle(cornerRadius: TeleopMetrics.corner)
                    .strokeBorder(TeleopColors.emergency.opacity(0.4), lineWidth: 1)
            )
            .padding(.top, 16)
            Spacer()
            HoldButton(
                titleKey: "stop.release_hold",
                fill: TeleopColors.card,
                border: TeleopColors.textSecondary.opacity(0.25),
                borderWidth: 1,
                foreground: TeleopColors.textPrimary,
                progress: TeleopColors.statusAmber.opacity(0.3),
                height: 56
            ) { model.send(.releaseStop) }
            .accessibilityIdentifier("stop.release")
            Text("stop.release_hint")
                .font(.system(size: 12))
                .foregroundStyle(TeleopColors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
                .padding(.bottom, 16)
            // Already latched; the session ignores a second stop, so this is a no-op that still answers the tap.
            StopButton { model.send(.stop) }
        }
        .padding(TeleopMetrics.margin)
    }
}
