import SwiftUI

/// The guide in the control surface: the workspace from above and from behind, one under the other on one left-right
/// axis, and the read-outs under them. It draws `GuidePicture` and decides nothing. Translucent, so the state colour
/// shows through; its words and drawings sit on dark backing, so they read on every state colour, gold included. It
/// takes no touches.
struct GuideView: View {
    let picture: GuidePicture
    /// The operating screen's height over the reference 874 pt.
    let scale: Double

    private var captionSize: Double { max(11, 13 * scale) }
    private var lineSize: Double { max(13, 15 * scale) }

    var body: some View {
        GeometryReader { proxy in
            let lineHeight = lineSize * 1.45
            let words = 2 * (captionSize * 1.4 + 2 + 2) + Double(picture.lines.count) * lineHeight + 2 * 4 + 4 * 4
            let room = max(0, proxy.size.height - words)
            let width = max(0, min(proxy.size.width, room / (1 / picture.aboveAspect + 1 / picture.behindAspect)))
            VStack(spacing: 4) {
                caption("guide.from_above")
                GuideAbove(picture: picture)
                    .frame(width: width, height: width / picture.aboveAspect)
                caption("guide.from_behind")
                GuideBehind(picture: picture)
                    .frame(width: width, height: width / picture.behindAspect)
                VStack(spacing: 0) {
                    ForEach(Array(picture.lines.enumerated()), id: \.offset) { _, line in
                        lineView(line)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(GuideInk.words, in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 4)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("guide")
    }

    private func caption(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.system(size: captionSize, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(GuideInk.words, in: Capsule())
    }

    private func lineView(_ line: GuidePicture.Line) -> some View {
        let text = GuideWords.text(line)
        let flag: Color? = switch line {
        case .onTarget, .holding: TeleopColors.guideOnTarget
        case .outside, .approximate: TeleopColors.guideTarget
        default: nil
        }
        return Text(verbatim: text)
            .font(.system(size: lineSize, weight: flag == nil ? .medium : .bold))
            .foregroundStyle(flag ?? .white)
            .multilineTextAlignment(.center)
            .frame(minHeight: lineSize * 1.45)
            .accessibilityIdentifier(Self.identifier(line))
    }

    static func identifier(_ line: GuidePicture.Line) -> String {
        switch line {
        case .height: return "readout.height"
        case .jaws: return "readout.jaws"
        case .wrist: return "readout.wrist"
        case .approximate: return "readout.approximate"
        case .target: return "readout.target"
        case .onTarget: return "readout.on_target"
        case .holding: return "readout.holding"
        case .goal: return "readout.goal"
        case .outside: return "readout.outside"
        }
    }
}

/// Shared drawing for the two views.
private enum GuideInk {
    /// Dark enough that white, the orange target and the green flags stay readable over the gold Saved state too.
    static let panel = Color.black.opacity(0.45)
    static let words = Color.black.opacity(0.55)
    static let frame = Color.white.opacity(0.25)
    static let box = Color.white.opacity(0.55)

    static func point(_ spot: GuidePicture.Spot, in size: CGSize) -> CGPoint {
        CGPoint(x: spot.x * size.width, y: spot.y * size.height)
    }

    static func square(at centre: CGPoint, edge: Double) -> CGRect {
        CGRect(x: centre.x - edge / 2, y: centre.y - edge / 2, width: edge, height: edge)
    }

    static func rect(_ area: GuidePicture.Area, in size: CGSize) -> CGRect {
        CGRect(x: area.minX * size.width, y: area.minY * size.height,
               width: (area.maxX - area.minX) * size.width, height: (area.maxY - area.minY) * size.height)
    }

    /// The ring around the pinch point: a little wider than the target, never too small to see.
    static func ringRadius(_ picture: GuidePicture, width: Double) -> Double {
        max(7, picture.targetEdge * width * 0.95)
    }

    static func jaws(_ picture: GuidePicture) -> Color { picture.onTarget ? TeleopColors.guideOnTarget : .white }

    /// The pinch point's outline. An approximate one is hollow: dashed, with no dot at its centre.
    static func outline(_ picture: GuidePicture, width: Double) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: picture.approximate ? [4, 3] : [])
    }

    static func centre(_ context: inout GraphicsContext, at pinch: CGPoint, _ picture: GuidePicture) {
        guard !picture.approximate else { return }
        context.fill(Path(ellipseIn: square(at: pinch, edge: 4)), with: .color(jaws(picture)))
    }

    /// What VoiceOver says of a view beyond its name: that the pinch point is approximate, as the read-out does.
    static func value(_ picture: GuidePicture) -> Text {
        Text(verbatim: picture.approximate ? GuideWords.text(.approximate) : "")
    }

    static func commanded(_ context: inout GraphicsContext, from: CGPoint, to: CGPoint, radius: Double) {
        context.stroke(Path { $0.move(to: from); $0.addLine(to: to) }, with: .color(.white.opacity(0.7)),
                       style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
        context.stroke(Path(ellipseIn: square(at: to, edge: radius * 2)), with: .color(.white.opacity(0.7)),
                       style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
    }

    static func backdrop<Content: View>(_ content: Content) -> some View {
        content
            .background(panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(frame, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// From above: the workspace box, the goal and the target when reported, where the arm is asked to go, and a ring
/// where the jaws pinch. Up is the operator's forward.
private struct GuideAbove: View {
    let picture: GuidePicture

    var body: some View {
        GuideInk.backdrop(
            Canvas { context, size in
                context.stroke(Path(GuideInk.rect(picture.boxAbove, in: size)), with: .color(GuideInk.box),
                               style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                if let goal = picture.goal {
                    let rect = GuideInk.square(at: GuideInk.point(goal.above, in: size), edge: picture.goalEdge * size.width)
                    context.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(TeleopColors.guideGoal),
                                   style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                }
                if let target = picture.target {
                    let rect = GuideInk.square(at: GuideInk.point(target.above, in: size), edge: picture.targetEdge * size.width)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(TeleopColors.guideTarget))
                }
                let pinch = GuideInk.point(picture.pinch.above, in: size)
                let radius = GuideInk.ringRadius(picture, width: size.width)
                if let commanded = picture.commanded {
                    GuideInk.commanded(&context, from: pinch, to: GuideInk.point(commanded.above, in: size), radius: radius)
                }
                context.stroke(Path(ellipseIn: GuideInk.square(at: pinch, edge: radius * 2)), with: .color(GuideInk.jaws(picture)),
                               style: GuideInk.outline(picture, width: picture.onTarget ? 4 : 2.5))
                GuideInk.centre(&context, at: pinch, picture)
            }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("guide.from_above"))
        .accessibilityValue(GuideInk.value(picture))
        .accessibilityIdentifier("guide.above")
    }
}

/// From behind: the table, the workspace box above it, the target and the goal when reported, a dotted drop from
/// the pinch point to the table, and the jaws opened as far as they are. Up is up.
private struct GuideBehind: View {
    let picture: GuidePicture

    var body: some View {
        GuideInk.backdrop(
            Canvas { context, size in
                let tableY = picture.tableY * size.height
                context.fill(Path(CGRect(x: 0, y: tableY, width: size.width, height: size.height - tableY)),
                             with: .color(.white.opacity(0.12)))
                context.stroke(Path { $0.move(to: CGPoint(x: 0, y: tableY)); $0.addLine(to: CGPoint(x: size.width, y: tableY)) },
                               with: .color(.white.opacity(0.7)), lineWidth: 2)
                context.stroke(Path(GuideInk.rect(picture.boxBehind, in: size)), with: .color(GuideInk.box),
                               style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                if let goal = picture.goal {
                    let centre = GuideInk.point(goal.behind, in: size)
                    let half = picture.goalEdge * size.width / 2
                    context.stroke(Path { $0.move(to: CGPoint(x: centre.x - half, y: centre.y)); $0.addLine(to: CGPoint(x: centre.x + half, y: centre.y)) },
                                   with: .color(TeleopColors.guideGoal), style: StrokeStyle(lineWidth: 4, dash: [5, 4]))
                }
                if let target = picture.target {
                    let rect = GuideInk.square(at: GuideInk.point(target.behind, in: size), edge: picture.targetEdge * size.width)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(TeleopColors.guideTarget))
                }
                let pinch = GuideInk.point(picture.pinch.behind, in: size)
                context.stroke(Path { $0.move(to: pinch); $0.addLine(to: CGPoint(x: pinch.x, y: tableY)) },
                               with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                let radius = GuideInk.ringRadius(picture, width: size.width)
                if let commanded = picture.commanded {
                    GuideInk.commanded(&context, from: pinch, to: GuideInk.point(commanded.behind, in: size), radius: radius)
                }
                drawJaws(&context, at: pinch, radius: radius)
            }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("guide.from_behind"))
        .accessibilityValue(GuideInk.value(picture))
        .accessibilityIdentifier("guide.behind")
    }

    /// Two jaws hanging from a bar, their tips at the pinch point, apart by how far they are open. Unreported, a
    /// plain ring.
    private func drawJaws(_ context: inout GraphicsContext, at pinch: CGPoint, radius: Double) {
        let ink = GuideInk.jaws(picture)
        guard let open = picture.jawOpening else {
            context.stroke(Path(ellipseIn: GuideInk.square(at: pinch, edge: radius * 2)), with: .color(ink),
                           style: GuideInk.outline(picture, width: 2.5))
            return
        }
        let half = 2 + (radius - 2) * open
        let rise = radius * 2.2
        context.stroke(
            Path {
                $0.move(to: CGPoint(x: pinch.x - half, y: pinch.y))
                $0.addLine(to: CGPoint(x: pinch.x - half, y: pinch.y - rise))
                $0.addLine(to: CGPoint(x: pinch.x + half, y: pinch.y - rise))
                $0.addLine(to: CGPoint(x: pinch.x + half, y: pinch.y))
            },
            with: .color(ink), style: GuideInk.outline(picture, width: picture.onTarget ? 4 : 3)
        )
        GuideInk.centre(&context, at: pinch, picture)
    }
}
