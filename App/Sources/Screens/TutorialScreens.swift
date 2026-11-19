import SwiftUI
import TeleopCore

/// T1 to T3: the controls from the operator's card (§0.3), for the mode chosen in Settings. Pages to read, not a lesson.
struct TutorialScreen: View {
    let model: AppModel
    let step: Int

    private struct Page {
        var title: LocalizedStringKey
        var lines: [LocalizedStringKey]
    }

    private var page: Page {
        let mode = model.controlMode
        switch step {
        case 1:
            switch mode {
            case .screenTurns:
                return Page(
                    title: "tutorial.keys.title",
                    lines: ["tutorial.keys.a", "tutorial.hold_rule", "tutorial.one_thing"])
            case .keyTurns:
                return Page(
                    title: "tutorial.keys.title",
                    lines: ["tutorial.keys.b", "tutorial.hold_rule", "tutorial.one_thing"])
            case .buttons:
                return Page(
                    title: "tutorial.buttons.title",
                    lines: ["tutorial.buttons.body", "tutorial.hold_rule", "tutorial.one_thing"])
            }
        case 2:
            switch mode {
            case .screenTurns:
                return Page(title: "tutorial.thumb.title_a", lines: ["tutorial.thumb.a_turn", "tutorial.thumb.a_open"])
            case .keyTurns:
                return Page(
                    title: "tutorial.thumb.title_b", lines: ["tutorial.thumb.b_halves", "tutorial.thumb.b_turn"])
            case .buttons: return Page(title: "tutorial.speed.title", lines: ["tutorial.speed.body"])
            }
        default:
            // Holding still while the arm catches up is for the phone's motion: a held arrow keeps moving the arm.
            let holdStill: [LocalizedStringKey] = mode == .buttons ? [] : ["tutorial.cue.hold_still"]
            // A tap needs the guide, which the phone modes draw with the task aid on; lock is a gesture of the keys and
            // the thumb, and the pad's arrows never latch.
            let taps = mode != .buttons && model.assist.goTo != nil && model.taskAid
            let tapKey: LocalizedStringKey =
                model.assist.views == nil ? "tutorial.cue.tap_to_go" : "tutorial.cue.tap_both_views"
            let tap: [LocalizedStringKey] = taps ? [tapKey] : []
            let lock: [LocalizedStringKey] = mode == .buttons ? [] : lockLine(model.assist.lock?.variant)
            // The guide's arrows name the picture's forward and up, while the arm follows the phone's heading at each
            // press: where the aids draw them, the guide's line also says they are not the hand's. Like the tap, they
            // are on screen only where the guide is, in the phone modes with the task aid on.
            let arrows = mode != .buttons && model.taskAid && model.assist.guide?.directionLabels == true
            let onTarget: LocalizedStringKey = arrows ? "tutorial.cue.on_target_arrows" : "tutorial.cue.on_target"
            return Page(
                title: "tutorial.cues.title",
                lines: ["tutorial.cue.stop", "tutorial.cue.reset", "tutorial.cue.go"]
                    + holdStill + [
                        "tutorial.cue.dead", "tutorial.cue.end", "tutorial.cue.letgo", onTarget, "tutorial.cue.grip",
                        "tutorial.cue.alarm",
                    ] + tap + lock)
        }
    }

    /// How the chosen lock latches and how it stops; nothing when no lock is in force.
    private func lockLine(_ variant: LockVariant?) -> [LocalizedStringKey] {
        switch variant {
        case .pressPress?: return ["tutorial.cue.lock_press"]
        case .holdThenSlide?: return ["tutorial.cue.lock_slide"]
        case nil: return []
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PracticeBanner(practice: model.operating.practice)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(format: L10n.string("tutorial.step_of"), step))
                        .font(.system(size: 14))
                        .foregroundStyle(TeleopColors.textSecondary)
                    Text(verbatim: OperatingWords.modeName(model.controlMode))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TeleopColors.primary)
                    Text(page.title)
                        .font(.system(size: 24, weight: .bold))
                        .accessibilityIdentifier("tutorial.title")
                    ForEach(Array(page.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 17))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(TeleopMetrics.margin)
            }
            HStack(spacing: 12) {
                if step == 3 {
                    Button {
                        model.send(.back)
                    } label: {
                        Text("common.back")
                    }
                    .buttonStyle(OutlineButtonStyle())
                    .accessibilityIdentifier("tutorial.back")
                } else {
                    Button {
                        model.send(.tutorialSkip)
                    } label: {
                        Text("common.skip")
                    }
                    .buttonStyle(OutlineButtonStyle())
                    .accessibilityIdentifier("tutorial.skip")
                }
                Button {
                    model.send(.tutorialNext(step: step))
                } label: {
                    Text(LocalizedStringKey(step == 3 ? "common.start" : "common.next"))
                }
                .buttonStyle(FilledButtonStyle())
                .accessibilityIdentifier("tutorial.next")
            }
            .padding(.horizontal, TeleopMetrics.margin)
            .padding(.vertical, 12)
            StopBand { model.send(.stop) }
        }
    }
}
