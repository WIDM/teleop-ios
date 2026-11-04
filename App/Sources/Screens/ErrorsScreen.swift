import SwiftUI

/// S7. Red only for the lost connection; other messages use an amber border.
struct ErrorsScreen: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                ConnectionChip(connected: false, heartbeatOk: false, lost: true) { model.send(.openConnection) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Label("errors.connection_lost", systemImage: "wifi.slash")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(TeleopColors.emergency)
                Text("errors.connection_lost_body")
                    .font(.system(size: 14))
                    .foregroundStyle(TeleopColors.textSecondary)
            }
            .card()
            .padding(.top, 16)
            Text("errors.heartbeat_timeout_body")
                .font(.system(size: 14))
                .foregroundStyle(TeleopColors.textSecondary)
                .card(border: TeleopColors.statusAmber)
                .padding(.top, 12)
            VStack(alignment: .leading, spacing: 4) {
                Text("errors.rejected_busy").font(.system(size: 16, weight: .semibold))
                Text("errors.rejected_busy_body")
                    .font(.system(size: 14))
                    .foregroundStyle(TeleopColors.textSecondary)
            }
            .card(border: TeleopColors.statusAmber)
            .padding(.top, 12)
            Spacer()
            HStack(spacing: 8) {
                Button { model.send(.reconnect) } label: { Text("errors.reconnect") }
                    .buttonStyle(FilledButtonStyle())
                    .accessibilityIdentifier("errors.reconnect")
                Button { model.send(.backToConnect) } label: { Text("errors.back_to_connect") }
                    .buttonStyle(OutlineButtonStyle())
                    .accessibilityIdentifier("errors.back_to_connect")
            }
            StopButton { model.send(.stop) }
                .padding(.top, 8)
        }
        .padding(TeleopMetrics.margin)
    }
}
