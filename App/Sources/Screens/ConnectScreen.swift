import SwiftUI
import TeleopCore

/// Connect (§7.1): the address, Connect, the real reason a connection failed, and practice without a robot.
struct ConnectScreen: View {
    @Bindable var model: AppModel

    var body: some View {
        let state = model.session.state
        VStack(alignment: .leading, spacing: 0) {
            PracticeBanner(practice: model.operating.practice)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("connect.title")
                        .font(.system(size: 28, weight: .bold))
                    if state.connectionLost {
                        Text("connect.connection_lost")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(TeleopColors.emergency)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("connect.connection_lost")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("connection.server_address")
                            .font(.system(size: 14))
                            .foregroundStyle(TeleopColors.textSecondary)
                        TextField(text: $model.session.state.serverAddress, prompt: Text(verbatim: "192.168.0.10:8765")) {
                            Text("connection.server_address")
                        }
                        .font(.system(size: 16, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                        .submitLabel(.go)
                        .onSubmit { model.connect() }
                        .padding(.horizontal, 12)
                        .frame(minHeight: TeleopMetrics.touch)
                        .background(
                            state.serverInputError ? TeleopColors.statusAmber.opacity(0.15) : TeleopColors.textSecondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: TeleopMetrics.corner)
                        )
                        .accessibilityIdentifier("connect.address_field")
                        if let reason = failure {
                            Text(verbatim: reason)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(TeleopColors.statusAmber)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("connect.failure")
                        }
                        HStack(spacing: 8) {
                            Button { model.connect() } label: { Text("connect.connect") }
                                .buttonStyle(FilledButtonStyle())
                                .accessibilityIdentifier("connect.connect")
                            Button { model.send(.s1Back) } label: { Text("common.back") }
                                .buttonStyle(OutlineButtonStyle())
                                .accessibilityIdentifier("connect.back")
                        }
                        .padding(.top, 4)
                    }
                    .card()
                    Button {
                        model.startPractice()
                        // Practice is the built-in demo: it is there at once, so go straight to the operating screen.
                        model.connect()
                    } label: { Text("connect.practice") }
                        .buttonStyle(OutlineButtonStyle(color: TeleopColors.practice))
                        .accessibilityIdentifier("connect.practice")
                }
                .padding(.horizontal, TeleopMetrics.margin)
                .padding(.top, 12)
            }
            StopBand { model.send(.stop) }
        }
    }

    /// Why the last attempt failed, as the link reported it; or that the address cannot be read.
    private var failure: String? {
        if model.session.state.serverInputError { return L10n.string("connect.input_error") }
        if case .notConnected(let reason?) = model.operating.state { return reason }
        return nil
    }
}
