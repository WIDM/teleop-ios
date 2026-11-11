import simd
import SwiftUI
import TeleopCore

struct ConnectionChip: View {
    var connected: Bool
    var amber = false
    var heartbeatOk = true
    var lost = false
    var onTap: (() -> Void)? = nil

    private var effectivelyConnected: Bool { connected && heartbeatOk }

    private var dotColor: Color {
        if lost { return TeleopColors.emergency }
        if !effectivelyConnected { return TeleopColors.textSecondary }
        return amber ? TeleopColors.statusAmber : TeleopColors.statusGreen
    }

    private var labelKey: LocalizedStringKey {
        if lost { return "status.disconnected" }
        return effectivelyConnected ? "status.connected" : "status.not_connected"
    }

    var body: some View {
        let content = HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 10, height: 10)
            Text(labelKey)
                .font(.system(size: 14))
                .foregroundStyle(TeleopColors.textPrimary)
            if onTap != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TeleopColors.textSecondary)
            }
        }
        .frame(minHeight: TeleopMetrics.touch)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())

        if let onTap {
            Button(action: onTap) { content }
                .buttonStyle(.plain)
                .accessibilityIdentifier("status.chip")
        } else {
            content
        }
    }
}

struct ModePill: View {
    let textKey: LocalizedStringKey

    var body: some View {
        Text(textKey)
            .font(.system(size: 14))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(TeleopColors.primary, in: Capsule())
    }
}

struct ControlStatusBar: View {
    let modeKey: LocalizedStringKey
    var connected: Bool
    var amber = false
    var heartbeatOk = true
    let onConnectionTap: () -> Void

    var body: some View {
        HStack {
            ModePill(textKey: modeKey)
            Spacer()
            ConnectionChip(connected: connected, amber: amber, heartbeatOk: heartbeatOk, onTap: onConnectionTap)
        }
        .frame(minHeight: TeleopMetrics.touch)
        .padding(.horizontal, 8)
        .background(TeleopColors.card, in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
    }
}

struct GripperCard: View {
    let gripper: GripperState
    var fullWidth = false

    var body: some View {
        VStack(spacing: 2) {
            Text(LocalizedStringKey(gripper == .open ? "control.gripper_open" : "control.gripper_closed"))
                .font(.system(size: 20, weight: .semibold))
            Text("control.gripper_pulse_hint")
                .font(.system(size: 14))
                .foregroundStyle(TeleopColors.textSecondary)
        }
        .foregroundStyle(TeleopColors.textPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: fullWidth ? .infinity : nil)
        .background(TeleopColors.gripperCard, in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
    }
}

struct VolumeHintBox: View {
    let textKey: LocalizedStringKey
    var onTap: (() -> Void)? = nil

    var body: some View {
        if let onTap {
            Button(action: onTap) { content }
                .buttonStyle(.plain)
                .accessibilityIdentifier("volume_hint")
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill")
            Text(textKey)
                .font(.system(size: 13))
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(TeleopColors.textSecondary)
        .padding(12)
        .background(TeleopColors.card.opacity(0.92), in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
    }
}

extension View {
    func card(border: Color? = nil) -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TeleopColors.card, in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
            .overlay(
                RoundedRectangle(cornerRadius: TeleopMetrics.corner)
                    .strokeBorder(border ?? .clear, lineWidth: 2)
            )
    }
}

/// Centre of the camera view. It answers, in this order: is the phone held right, where is the arm being
/// sent (during a live hold), and where is the thing to reach. With none of those it is the plain crosshair.
struct AimOrOffset: View {
    let model: AppModel

    var body: some View {
        content(posture: model.posture)
    }

    @ViewBuilder
    private func content(posture: PhonePosture) -> some View {
        if posture == .tilted {
            VStack(spacing: 8) {
                Image(systemName: "iphone.gen3").font(.system(size: 56, weight: .light))
                Text("guide.hold_upright").font(.system(size: 26, weight: .bold))
                Text("guide.hold_upright_hint").font(.system(size: 14))
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(TeleopColors.statusAmber)
            .padding(.horizontal, 8)
            .accessibilityIdentifier("guide.hold_upright")
        } else if let guidance = model.guidance {
            VStack(spacing: 6) {
                MiniMap(guidance: guidance)
                if guidance.target == .done {
                    Text("guide.done").font(.system(size: 15, weight: .semibold))
                } else if guidance.wristTilted {
                    Text("guide.wrist_tilted")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TeleopColors.statusAmber)
                        .accessibilityIdentifier("guide.wrist_tilted")
                } else if guidance.readyToGrasp {
                    Text("guide.ready_to_grasp")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(TeleopColors.statusGreen)
                        .accessibilityIdentifier("guide.ready_to_grasp")
                } else {
                    Text(guidance.target == .goal ? "guide.map_caption_carry" : "guide.map_caption")
                        .font(.system(size: 11)).opacity(0.8)
                }
                if guidance.target == .cube, guidance.turnJawsFirst {
                    Text("guide.turn_jaws_hint")
                        .font(.system(size: 11, weight: .semibold))
                        .accessibilityIdentifier("guide.turn_jaws_hint")
                }
                if model.catchingUp {
                    Text("control.catching_up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TeleopColors.statusAmber)
                        .accessibilityIdentifier("control.catching_up")
                }
                if guidance.atEdge {
                    Text("guide.edge")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TeleopColors.statusAmber)
                }
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            // No wider than the two views, so the text wraps instead of running under the side handles.
            .frame(width: CGFloat(MiniMapLayout.guideWidth))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("control.centre")
        } else {
            VStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 40, weight: .light))
                Text("control.gripper_aim").font(.system(size: 14))
            }
            .foregroundStyle(.white)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("control.centre")
        }
    }
}

/// The task in two pictures that share one left-right axis and one scale, so a thing is at the same x in both.
/// From above: a ring where the jaws pinch, a red square for the cube, a dashed green square for the goal, a grey
/// marker for the robot base. From behind: the table as a line, the cube sitting on it, the goal on it, the ring
/// at the height of the jaw tips with a plain pair of jaws above it, and the gap in height between the jaw tips and
/// the cube. Ring on the red square in both and the ring turns green: close the jaws.
struct MiniMap: View {
    let guidance: Guidance
    private let jawsColor: Color

    init(guidance: Guidance) {
        self.guidance = guidance
        jawsColor = guidance.readyToGrasp ? TeleopColors.statusGreen : .white
    }

    var body: some View {
        let layout = MiniMapLayout(guidance)
        VStack(spacing: 3) {
            caption("guide.from_above")
            topView(layout)
            caption("guide.from_behind")
            sideView(layout)
        }
    }

    private func caption(_ key: LocalizedStringKey) -> some View {
        Text(key).font(.system(size: 11, weight: .semibold)).opacity(0.7)
    }

    private func panel<Content: View>(width: Float, height: Float, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: CGFloat(width), height: CGFloat(height))
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
    }

    private func point(_ p: SIMD2<Float>) -> CGPoint { CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)) }

    private func box(centre: SIMD2<Float>, width: Float, height: Float) -> CGRect {
        CGRect(x: CGFloat(centre.x - width / 2), y: CGFloat(centre.y - height / 2), width: CGFloat(width), height: CGFloat(height))
    }

    private func topView(_ layout: MiniMapLayout) -> some View {
        panel(width: layout.width, height: layout.topHeight) {
            Canvas { context, _ in
                func square(_ place: SIMD3<Float>, _ meters: Float) -> CGRect {
                    let edge = layout.length(meters)
                    return box(centre: layout.top(place), width: edge, height: edge)
                }
                context.stroke(
                    Path(roundedRect: square(layout.goal, MiniMapLayout.goalSize), cornerRadius: 3),
                    with: .color(TeleopColors.statusGreen), style: StrokeStyle(lineWidth: 2, dash: [5, 4])
                )
                context.fill(
                    Path(roundedRect: square(layout.cube, layout.cubeSize), cornerRadius: 2),
                    with: .color(TeleopColors.emergency)
                )
                let base = box(centre: layout.base, width: 9, height: 9)
                context.fill(Path(roundedRect: base, cornerRadius: 2), with: .color(.gray))
                let ring = square(layout.arm, layout.cubeSize * MiniMapLayout.ringToCube)
                context.stroke(Path(ellipseIn: ring), with: .color(jawsColor), lineWidth: guidance.readyToGrasp ? 4 : 2.5)
                context.fill(Path(ellipseIn: CGRect(x: ring.midX - 2, y: ring.midY - 2, width: 4, height: 4)), with: .color(jawsColor))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("guide.map")
    }

    private func sideView(_ layout: MiniMapLayout) -> some View {
        panel(width: layout.width, height: layout.sideHeight) {
            ZStack {
                Canvas { context, size in
                    let table = layout.tableY
                    context.stroke(
                        Path { $0.move(to: CGPoint(x: 0, y: CGFloat(table))); $0.addLine(to: CGPoint(x: size.width, y: CGFloat(table))) },
                        with: .color(.white.opacity(0.5)), lineWidth: 2
                    )
                    let goal = layout.sideGoal
                    context.stroke(
                        Path { $0.move(to: CGPoint(x: CGFloat(goal.minX), y: CGFloat(goal.y))); $0.addLine(to: CGPoint(x: CGFloat(goal.maxX), y: CGFloat(goal.y))) },
                        with: .color(TeleopColors.statusGreen), style: StrokeStyle(lineWidth: 4, dash: [5, 4])
                    )
                    let cube = layout.sideCube
                    context.fill(
                        Path(roundedRect: box(centre: cube.centre, width: cube.edge, height: cube.edge), cornerRadius: 2),
                        with: .color(TeleopColors.emergency)
                    )
                    if let line = layout.gapLine {
                        let ink = Color.white.opacity(0.85)
                        // The cube's centre height, carried across to the line, then the line itself between the two heights.
                        context.stroke(
                            Path { $0.move(to: CGPoint(x: CGFloat(layout.sideCube.centre.x), y: CGFloat(line.targetY))); $0.addLine(to: CGPoint(x: CGFloat(line.x), y: CGFloat(line.targetY))) },
                            with: .color(ink.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 3])
                        )
                        context.stroke(
                            Path {
                                $0.move(to: CGPoint(x: CGFloat(line.x), y: CGFloat(line.ringY)))
                                $0.addLine(to: CGPoint(x: CGFloat(line.x), y: CGFloat(line.targetY)))
                                for y in [line.ringY, line.targetY] {
                                    $0.move(to: CGPoint(x: CGFloat(line.x - 3), y: CGFloat(y)))
                                    $0.addLine(to: CGPoint(x: CGFloat(line.x + 3), y: CGFloat(y)))
                                }
                            },
                            with: .color(ink), lineWidth: 1
                        )
                    }
                    let ring = layout.ring
                    let radius = layout.length(layout.cubeSize * MiniMapLayout.ringToCube) / 2
                    // Two jaws: bars hanging from a bar across the top, their tips on the ring.
                    context.stroke(
                        Path {
                            $0.move(to: CGPoint(x: CGFloat(ring.x - radius), y: CGFloat(ring.y)))
                            $0.addLine(to: CGPoint(x: CGFloat(ring.x - radius), y: CGFloat(ring.y - MiniMapLayout.jawRise)))
                            $0.addLine(to: CGPoint(x: CGFloat(ring.x + radius), y: CGFloat(ring.y - MiniMapLayout.jawRise)))
                            $0.addLine(to: CGPoint(x: CGFloat(ring.x + radius), y: CGFloat(ring.y)))
                        },
                        with: .color(jawsColor), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                    )
                    let ringBox = box(centre: ring, width: radius * 2, height: MiniMapLayout.ringThickness)
                    context.stroke(Path(ellipseIn: ringBox), with: .color(jawsColor), lineWidth: guidance.readyToGrasp ? 3.5 : 2)
                    context.fill(Path(ellipseIn: CGRect(x: ringBox.midX - 2, y: ringBox.midY - 2, width: 4, height: 4)), with: .color(jawsColor))
                }
                if let gap = layout.heightGap, let line = layout.gapLine {
                    Text(Self.gapText(gap))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: CGFloat(MiniMapLayout.labelWidth), height: CGFloat(MiniMapLayout.labelHeight))
                        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4))
                        .position(point(line.label))
                        .accessibilityIdentifier("guide.height_gap")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("guide.side_view")
    }

    static func gapText(_ gap: MiniMapLayout.HeightGap) -> String {
        switch gap.kind {
        case .level: L10n.string("guide.gap_level")
        case .above: String(format: L10n.string("guide.gap_above"), String(format: "%.1f", gap.centimetres))
        case .below: String(format: L10n.string("guide.gap_below"), String(format: "%.1f", gap.centimetres))
        }
    }
}

struct ServerAddressField: View {
    /// Shown greyed in an empty address field, so the expected form is visible without pretending to be an address.
    static let example = "192.168.0.10:8765"

    let address: String
    let error: Bool

    var body: some View {
        Text(address.isEmpty ? Self.example : address)
            .font(.system(size: 16, design: .monospaced))
            .foregroundStyle(address.isEmpty ? TeleopColors.textSecondary : TeleopColors.textPrimary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: TeleopMetrics.touch, alignment: .leading)
            .background(
                (error ? TeleopColors.statusAmber.opacity(0.15) : TeleopColors.textSecondary.opacity(0.08)),
                in: RoundedRectangle(cornerRadius: TeleopMetrics.corner)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TeleopMetrics.corner)
                    .strokeBorder(error ? TeleopColors.statusAmber : .clear, lineWidth: 2)
            )
    }
}
