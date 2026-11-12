import SwiftUI

extension View {
    func card() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TeleopColors.card, in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
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
