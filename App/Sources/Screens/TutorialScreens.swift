import SwiftUI
import TeleopCore

/// T1 to T3: tip cards over a dimmed standby view. STOP stays above the scrim.
struct TutorialScreen: View {
    let model: AppModel
    let step: Int

    private var titleKey: LocalizedStringKey {
        switch step {
        case 1: return "tutorial.t1.title"
        case 2: return "tutorial.t2.title"
        default: return "tutorial.t3.title"
        }
    }

    private var bodyKey: LocalizedStringKey {
        switch step {
        case 1: return "tutorial.t1.body"
        case 2: return "tutorial.t2.body"
        default: return "tutorial.t3.body"
        }
    }

    var body: some View {
        ZStack {
            StandbyScreen(model: model, showStop: false)
                .allowsHitTesting(false)
            VStack(spacing: 8) {
                ZStack {
                    TeleopColors.scrim
                    card.padding(.horizontal, 24)
                }
                StopButton { model.send(.stop) }
                    .padding(.horizontal, TeleopMetrics.margin)
            }
            .padding(.bottom, 12)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(format: String(localized: "tutorial.step_of"), step))
                .font(.system(size: 14))
                .foregroundStyle(TeleopColors.textSecondary)
            Text(titleKey).font(.system(size: 20, weight: .semibold))
            Text(bodyKey).font(.system(size: 14)).foregroundStyle(TeleopColors.textSecondary)
            HStack(spacing: 12) {
                if step == 3 {
                    Button { model.send(.back) } label: { Text("common.back") }
                        .buttonStyle(OutlineButtonStyle())
                        .accessibilityIdentifier("tutorial.back")
                } else {
                    Button { model.send(.tutorialSkip) } label: { Text("common.skip") }
                        .buttonStyle(OutlineButtonStyle())
                        .accessibilityIdentifier("tutorial.skip")
                }
                Button { model.send(.tutorialNext(step: step)) } label: {
                    Text(LocalizedStringKey(step == 3 ? "common.start" : "common.next"))
                }
                .buttonStyle(FilledButtonStyle())
                .accessibilityIdentifier("tutorial.next")
            }
            .padding(.top, 8)
        }
        .padding(20)
        .background(TeleopColors.card, in: RoundedRectangle(cornerRadius: 16))
    }
}
