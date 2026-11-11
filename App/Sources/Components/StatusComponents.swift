import SwiftUI

extension View {
    func card() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TeleopColors.card, in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
    }
}

/// The old cube guide's height read-out. Nothing draws it any more; `GuidanceTests` still checks its words, so it
/// stays until those tests move to `GuidePicture`.
enum MiniMap {
    static func gapText(_ gap: MiniMapLayout.HeightGap) -> String {
        switch gap.kind {
        case .level: L10n.string("guide.gap_level")
        case .above: String(format: L10n.string("guide.gap_above"), String(format: "%.1f", gap.centimetres))
        case .below: String(format: L10n.string("guide.gap_below"), String(format: "%.1f", gap.centimetres))
        }
    }
}

/// Practice marks for the screens other than the operating screen: the purple stripes and PRACTICE 練習 across the
/// top (§7.4). Nothing when not practising.
struct PracticeBanner: View {
    let practice: Bool

    var body: some View {
        if practice {
            PracticeMark(size: 14)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(PracticeStripes().ignoresSafeArea(edges: .top))
        }
    }
}
