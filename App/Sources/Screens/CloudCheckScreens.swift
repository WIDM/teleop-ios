import SwiftUI
import TeleopCore

struct CloudCheckPassScreen: View {
    let model: AppModel

    var body: some View {
        CloudCheckScaffold(
            model: model,
            subtitle: "cloud.must_pass",
            heartbeatOk: true,
            physicalOk: true,
            primaryKey: "cloud.enter_standby",
            primary: { model.send(.cloudEnterStandby) },
            secondaryKey: "common.back",
            secondary: { model.send(.back) },
            help: nil,
            demoFailAction: { model.send(.cloudSimulateFail) }
        )
    }
}

struct CloudCheckFailScreen: View {
    let model: AppModel

    var body: some View {
        let state = model.session.state
        CloudCheckScaffold(
            model: model,
            subtitle: "cloud.failed_hint",
            heartbeatOk: state.heartbeatOk,
            physicalOk: state.physicalEstopOk,
            primaryKey: "cloud.recheck",
            primary: { model.send(.cloudRecheck) },
            secondaryKey: "cloud.use_on_site",
            secondary: { model.send(.cloudUseOnSite) },
            help: "cloud.fail_help",
            demoFailAction: nil
        )
    }
}

private struct CloudCheckScaffold: View {
    let model: AppModel
    let subtitle: LocalizedStringKey
    let heartbeatOk: Bool
    let physicalOk: Bool
    let primaryKey: LocalizedStringKey
    let primary: () -> Void
    let secondaryKey: LocalizedStringKey
    let secondary: () -> Void
    let help: LocalizedStringKey?
    let demoFailAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("cloud.title")
                .font(.system(size: 28, weight: .bold))
                .padding(.top, 48)
                // Demo only, not in Figma: P3 has no real trigger until the robot link exists.
                .onLongPressGesture(minimumDuration: 1) { demoFailAction?() }
                .accessibilityActions {
                    if let demoFailAction {
                        Button("demo.simulate_fail", action: demoFailAction)
                    }
                }
                .accessibilityIdentifier("cloud.title")
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(TeleopColors.textSecondary)
                .padding(.top, 8)
            checkRow("connection.heartbeat", detail: heartbeatOk ? "connection.heartbeat_ok" : "connection.heartbeat_missing", ok: heartbeatOk)
                .padding(.top, 16)
            checkRow("cloud.physical_estop", detail: "cloud.physical_estop_ok", ok: physicalOk)
                .padding(.top, 12)
            if let help {
                Text(help)
                    .font(.system(size: 14))
                    .foregroundStyle(TeleopColors.textSecondary)
                    .padding(.top, 16)
            }
            Spacer()
            Button(action: primary) { Text(primaryKey) }
                .buttonStyle(FilledButtonStyle())
                .accessibilityIdentifier("cloud.primary")
            Button(action: secondary) { Text(secondaryKey) }
                .buttonStyle(OutlineButtonStyle())
                .accessibilityIdentifier("cloud.secondary")
                .padding(.top, 12)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 24)
    }

    private func checkRow(_ title: LocalizedStringKey, detail: LocalizedStringKey, ok: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16))
                Text(detail).font(.system(size: 14)).foregroundStyle(TeleopColors.textSecondary)
            }
            Spacer()
            Text(LocalizedStringKey(ok ? "cloud.pass" : "cloud.fail"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ok ? TeleopColors.statusGreen : TeleopColors.statusAmber)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    ok ? TeleopColors.passSoft : TeleopColors.failSoft,
                    in: RoundedRectangle(cornerRadius: 8)
                )
        }
        .card(border: ok ? nil : TeleopColors.statusAmber)
    }
}
