import SwiftUI
import TeleopCore

/// S1. Back and Connect return to P5; Disconnect goes to S7.
struct ConnectScreen: View {
    let model: AppModel

    var body: some View {
        let state = model.session.state
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                ConnectionChip(connected: false, heartbeatOk: false) { model.send(.openConnection) }
            }
            .padding(.horizontal, 8)
            .background(TeleopColors.card, in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
            Text("connect.title")
                .font(.system(size: 28, weight: .bold))
                .padding(.top, 16)
            Text("connect.subtitle")
                .font(.system(size: 14))
                .foregroundStyle(TeleopColors.textSecondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("connection.server_address")
                    .font(.system(size: 14))
                    .foregroundStyle(TeleopColors.textSecondary)
                ServerAddressField(address: state.serverAddress, error: state.serverInputError)
                if state.serverInputError {
                    Text("connect.input_error")
                        .font(.system(size: 12))
                        .foregroundStyle(TeleopColors.statusAmber)
                }
                HStack(spacing: 8) {
                    Button { model.send(.connect) } label: {
                        Label("connect.connect", systemImage: "link")
                    }
                    .buttonStyle(FilledButtonStyle())
                    .accessibilityIdentifier("connect.connect")
                    Button { model.send(.disconnect) } label: {
                        Label("connect.disconnect", systemImage: "bolt.slash")
                    }
                    .buttonStyle(OutlineButtonStyle())
                    .accessibilityIdentifier("connect.disconnect")
                }
                .padding(.top, 4)
            }
            .card()
            .padding(.top, 16)

            VStack(alignment: .leading, spacing: 0) {
                Text("connect.recent")
                    .font(.system(size: 14))
                    .foregroundStyle(TeleopColors.textSecondary)
                    .padding(.bottom, 4)
                recentRow("connect.recent_lab_wifi")
                recentRow("connect.recent_hotspot")
            }
            .card()
            .padding(.top, 16)

            Text("connect.hint")
                .font(.system(size: 12))
                .foregroundStyle(TeleopColors.textSecondary)
                .padding(.top, 12)

            Button { model.send(.s1Back) } label: {
                Label("common.back", systemImage: "arrow.left")
            }
            .buttonStyle(OutlineButtonStyle())
            .accessibilityIdentifier("connect.back")
            .padding(.top, 8)

            Spacer(minLength: 8)
            StopButton { model.send(.stop) }
        }
        .padding(.horizontal, TeleopMetrics.margin)
        .padding(.vertical, 12)
    }

    private func recentRow(_ key: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(TeleopColors.textSecondary)
            Text(key).font(.system(size: 16))
            Spacer()
        }
        .frame(minHeight: TeleopMetrics.touch)
    }
}
