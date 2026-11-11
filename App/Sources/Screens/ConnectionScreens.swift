import SwiftUI
import TeleopCore

/// P5 and P7: connection sheet over the standby view. Latency is shown only here.
struct ConnectionDetailsScreen: View {
    @Bindable var model: AppModel
    let keyboardExpanded: Bool
    @FocusState private var addressFocused: Bool

    var body: some View {
        let state = model.session.state
        let amber = state.latencyIsAmber
        ZStack {
            StandbyScreen(model: model, highLatency: state.commandsBlocked, showStop: false)
                .allowsHitTesting(false)
            TeleopColors.scrim.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 0) {
                    Text("connection.title")
                        .font(.system(size: 22, weight: .semibold))
                        .padding(.bottom, 12)
                    detailRow(
                        dot: amber ? TeleopColors.statusAmber : TeleopColors.statusGreen,
                        label: "connection.latency",
                        value: latencyText(state)
                    )
                    .accessibilityIdentifier("connection.latency_row")
                    Text("connection.server_address")
                        .font(.system(size: 14))
                        .foregroundStyle(TeleopColors.textSecondary)
                        .padding(.top, 8)
                    addressField(state)
                        .padding(.top, 6)
                    if !keyboardExpanded {
                        changeServerRow
                    }
                    if keyboardExpanded {
                        Button { model.send(.keyboardDone) } label: { Text("keyboard.done") }
                            .buttonStyle(FilledButtonStyle())
                            .accessibilityIdentifier("keyboard.done")
                            .padding(.top, 12)
                    } else {
                        Button { model.send(.closeConnection) } label: { Text("connection.close") }
                            .buttonStyle(OutlineButtonStyle())
                            .accessibilityIdentifier("connection.close")
                            .padding(.top, 8)
                    }
                }
                .padding(20)
                .background(
                    TeleopColors.card,
                    in: UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16)
                )
                StopButton { model.send(.stop) }
                    .padding(.horizontal, TeleopMetrics.margin)
                    .padding(.vertical, 8)
            }
        }
        .onAppear { addressFocused = keyboardExpanded }
    }

    @ViewBuilder
    private func addressField(_ state: FakeTeleopState) -> some View {
        if keyboardExpanded {
            TextField(ServerAddressField.example, text: $model.session.state.serverAddress)
                .focused($addressFocused)
                .font(.system(size: 16, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.numbersAndPunctuation)
                .padding(.horizontal, 12)
                .frame(minHeight: TeleopMetrics.touch)
                .background(TeleopColors.textSecondary.opacity(0.08), in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
                .accessibilityIdentifier("connection.address_field")
        } else {
            Button { model.send(.openKeyboard) } label: {
                ServerAddressField(address: state.serverAddress, error: state.serverInputError)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("connection.address")
        }
        if state.serverInputError {
            Text("connect.input_error")
                .font(.system(size: 12))
                .foregroundStyle(TeleopColors.statusAmber)
        }
    }

    private var changeServerRow: some View {
        Button { model.send(.changeServer) } label: {
            HStack {
                Text("connection.change_server").font(.system(size: 16))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(TeleopColors.chevronMuted)
            }
            .frame(minHeight: TeleopMetrics.touch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(TeleopColors.textPrimary)
        .accessibilityIdentifier("connection.change_server")
    }

    private func latencyText(_ state: FakeTeleopState) -> String {
        let format = state.latencyIsAmber
            ? L10n.string("connection.latency_high")
            : L10n.string("connection.latency_normal")
        return String(format: format, state.latencyMs)
    }

    private func detailRow(dot: Color, label: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 10, height: 10)
            Text(label).font(.system(size: 16))
            Text(value).font(.system(size: 16)).foregroundStyle(TeleopColors.textSecondary)
            Spacer()
        }
        .frame(minHeight: TeleopMetrics.touch)
    }
}
