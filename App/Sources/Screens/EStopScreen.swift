import SwiftUI

/// S4: emergency stop active. Release needs a 1 second hold.
struct EStopScreen: View {
    let model: AppModel

    var body: some View {
        let state = model.session.state
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ModePill(textKey: "control.standby")
                Spacer()
                ConnectionChip(connected: state.connected, heartbeatOk: state.heartbeatOk) { model.send(.openConnection) }
            }
            .frame(minHeight: TeleopMetrics.touch)
            .padding(.horizontal, 8)
            .background(TeleopColors.emergency.opacity(0.12), in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
            Text("stop.active")
                .font(.system(size: 22, weight: .semibold))
                .padding(.top, 24)
            Text("stop.hold_hint")
                .font(.system(size: 14))
                .foregroundStyle(TeleopColors.textSecondary)
            HoldButton(
                titleKey: "stop.release_hold",
                fill: TeleopColors.emergency,
                border: TeleopColors.emergencyBorder,
                height: TeleopMetrics.stopHeight
            ) { model.send(.releaseStop) }
            .accessibilityIdentifier("stop.release")
            .padding(.top, 24)
            Spacer()
            StopButton {}
        }
        .padding(TeleopMetrics.margin)
    }
}
