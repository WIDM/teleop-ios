import SwiftUI
import TeleopCore

struct PermissionsScreen: View {
    let model: AppModel

    var body: some View {
        let state = model.session.state
        VStack(alignment: .leading, spacing: 0) {
            ControlStatusBar(
                modeKey: "control.setup",
                connected: state.connected,
                heartbeatOk: state.heartbeatOk
            ) { model.send(.openConnection) }
            Text("permissions.title")
                .font(.system(size: 22, weight: .semibold))
                .padding(.top, 16)
            permissionCard("permissions.camera", "permissions.camera_body", icon: "camera")
                .padding(.top, 12)
            permissionCard("permissions.motion", "permissions.motion_body", icon: "gyroscope")
                .padding(.top, 12)
            Spacer()
            Text("permissions.hint")
                .font(.system(size: 12))
                .foregroundStyle(TeleopColors.textSecondary)
            Button { model.send(.permissionsContinue) } label: { Text("common.continue") }
                .buttonStyle(FilledButtonStyle())
                .accessibilityIdentifier("permissions.continue")
                .padding(.top, 8)
            StopButton { model.send(.stop) }
                .padding(.top, 8)
        }
        .padding(TeleopMetrics.margin)
    }

    private func permissionCard(_ title: LocalizedStringKey, _ body: LocalizedStringKey, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(TeleopColors.primary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(body).font(.system(size: 14)).foregroundStyle(TeleopColors.textSecondary)
            }
        }
        .card()
    }
}
