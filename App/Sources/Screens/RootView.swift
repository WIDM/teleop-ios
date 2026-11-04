import SwiftUI
import TeleopCore

struct RootView: View {
    let model: AppModel

    var body: some View {
        ZStack {
            TeleopColors.background.ignoresSafeArea()
            screen(for: model.session.route)
        }
        .foregroundStyle(TeleopColors.textPrimary)
        .task(id: model.session.state.isRecording) {
            guard model.session.state.isRecording else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                model.send(.recordingTick)
            }
        }
    }

    @ViewBuilder
    private func screen(for route: Route) -> some View {
        switch route {
        case .p1: ModeSelectScreen(model: model)
        case .p2: CloudCheckPassScreen(model: model)
        case .p3: CloudCheckFailScreen(model: model)
        case .p4: StandbyScreen(model: model)
        case .p5: ConnectionDetailsScreen(model: model, keyboardExpanded: false)
        case .p6: StandbyScreen(model: model, highLatency: true)
        case .p7: ConnectionDetailsScreen(model: model, keyboardExpanded: true)
        case .t1: TutorialScreen(model: model, step: 1)
        case .t2: TutorialScreen(model: model, step: 2)
        case .t3: TutorialScreen(model: model, step: 3)
        case .s1: ConnectScreen(model: model)
        case .s2: PermissionsScreen(model: model)
        case .s3a: RecordingScreen(model: model, fallback: false)
        case .s3b: RecordEndScreen(model: model)
        case .s3m: BaseTeleopScreen(model: model)
        case .s4: EStopScreen(model: model)
        case .s5: FallbackControlScreen(model: model)
        case .s5a: RecordingScreen(model: model, fallback: true)
        case .s6: SettingsScreen(model: model)
        case .s7: ErrorsScreen(model: model)
        }
    }
}
