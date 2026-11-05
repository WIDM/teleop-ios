import SwiftUI
import TeleopCore

struct ModeSelectScreen: View {
    @Bindable var model: AppModel

    var body: some View {
        let mode = model.session.state.mode
        VStack(alignment: .leading, spacing: 0) {
            Text("mode.choose")
                .font(.system(size: 28, weight: .bold))
                .padding(.top, 48)
            Text("mode.hint")
                .font(.system(size: 14))
                .foregroundStyle(TeleopColors.textSecondary)
                .padding(.top, 8)
            modeCard("mode.on_site", "mode.on_site_desc", selected: mode == .onSite, id: "mode.on_site") {
                model.session.state.selectOnSite()
            }
            .padding(.top, 16)
            modeCard("mode.cloud", "mode.cloud_desc", selected: mode == .cloud, id: "mode.cloud") {
                model.session.state.selectCloud()
            }
            .padding(.top, 12)
            Spacer()
            Button { model.send(.modeNext) } label: { Text("common.next") }
                .buttonStyle(FilledButtonStyle())
                .accessibilityIdentifier("mode.next")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 24)
    }

    private func modeCard(
        _ title: LocalizedStringKey,
        _ desc: LocalizedStringKey,
        selected: Bool,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.system(size: 16, weight: .semibold))
                    Spacer()
                    if selected {
                        Label("mode.selected", systemImage: "circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(TeleopColors.statusGreen)
                    } else {
                        Image(systemName: "circle").foregroundStyle(TeleopColors.textSecondary)
                    }
                }
                Text(desc)
                    .font(.system(size: 14))
                    .foregroundStyle(TeleopColors.textSecondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TeleopColors.card, in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
            .overlay(
                RoundedRectangle(cornerRadius: TeleopMetrics.corner)
                    .strokeBorder(
                        selected ? TeleopColors.primary : TeleopColors.textSecondary.opacity(0.3),
                        lineWidth: selected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}
