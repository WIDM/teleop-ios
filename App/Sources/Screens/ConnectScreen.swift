import SwiftUI
import TeleopCore

/// S1. Back and Connect return to P5; Disconnect ends the link and stays here.
struct ConnectScreen: View {
    let model: AppModel

    var body: some View {
        let state = model.session.state
        @Bindable var model = model
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
            if state.connectionLost {
                Text("connect.connection_lost")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(TeleopColors.emergency)
                    .padding(.top, 8)
                    .accessibilityIdentifier("connect.connection_lost")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("connection.server_address")
                    .font(.system(size: 14))
                    .foregroundStyle(TeleopColors.textSecondary)
                if state.liveLink {
                    // The real server address is typed here; the demo link only shows it.
                    TextField(ServerAddressField.example, text: $model.session.state.serverAddress)
                        .font(.system(size: 16, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                        .submitLabel(.go)
                        .onSubmit { model.connect() }
                        .padding(.horizontal, 12)
                        .frame(minHeight: TeleopMetrics.touch)
                        .background(
                            (state.serverInputError ? TeleopColors.statusAmber.opacity(0.15) : TeleopColors.textSecondary.opacity(0.08)),
                            in: RoundedRectangle(cornerRadius: TeleopMetrics.corner)
                        )
                        .accessibilityIdentifier("connect.address_field")
                } else {
                    ServerAddressField(address: state.serverAddress, error: state.serverInputError)
                }
                if state.serverInputError {
                    Text("connect.input_error")
                        .font(.system(size: 12))
                        .foregroundStyle(TeleopColors.statusAmber)
                }
                HStack(spacing: 8) {
                    Button { model.connect() } label: {
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
}
