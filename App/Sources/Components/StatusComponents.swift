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
    var color: Color = TeleopColors.primary
    var showsDot = false

    var body: some View {
        HStack(spacing: 6) {
            if showsDot { Circle().fill(.white).frame(width: 10, height: 10) }
            Text(textKey).font(.system(size: 14))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(color, in: Capsule())
    }
}

struct ControlStatusBar: View {
    let modeKey: LocalizedStringKey
    var connected: Bool
    var amber = false
    var heartbeatOk = true
    var recording = false
    var onModeLongPress: (() -> Void)? = nil
    let onConnectionTap: () -> Void

    var body: some View {
        HStack {
            pill
            Spacer()
            ConnectionChip(connected: connected, amber: amber, heartbeatOk: heartbeatOk, onTap: onConnectionTap)
        }
        .frame(minHeight: TeleopMetrics.touch)
        .padding(.horizontal, 8)
        .background(TeleopColors.card, in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
    }

    @ViewBuilder
    private var pill: some View {
        let base = ModePill(
            textKey: modeKey,
            color: recording ? TeleopColors.recording : TeleopColors.primary,
            showsDot: recording
        )
        if let onModeLongPress {
            base
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 1, perform: onModeLongPress)
                .accessibilityIdentifier("status.mode_pill")
        } else {
            base
        }
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

struct BlinkingDot: View {
    var color: Color = .white
    var size: CGFloat = 8
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(dim ? 0.15 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { dim = true }
            }
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
                } else if guidance.readyToGrasp {
                    Text("guide.ready_to_grasp")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(TeleopColors.statusGreen)
                        .accessibilityIdentifier("guide.ready_to_grasp")
                } else {
                    Text(guidance.target == .goal ? "guide.map_caption_carry" : "guide.map_caption")
                        .font(.system(size: 11)).opacity(0.8)
                }
                if guidance.target == .cube {
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
            // No wider than the map and its bar, so the text wraps instead of running under the side handles.
            .frame(width: 198)
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

/// Top-down picture of the task: a ring where the jaws pinch, a red square for the cube, a dashed green square
/// for the goal. Up is the operator's forward. The bar on the right is height. Ring on the red square in both,
/// and the ring turns green: close the jaws.
struct MiniMap: View {
    let guidance: Guidance
    private let side: CGFloat = 168
    private let barWidth: CGFloat = 22

    var body: some View {
        let layout = MiniMapLayout(guidance)
        HStack(spacing: 8) {
            Canvas { context, _ in
                let side = Float(self.side)
                func rect(_ place: SIMD3<Float>, _ meters: Float) -> CGRect {
                    let centre = layout.point(place, side: side)
                    let edge = CGFloat(layout.length(meters, side: side))
                    return CGRect(x: CGFloat(centre.x) - edge / 2, y: CGFloat(centre.y) - edge / 2, width: edge, height: edge)
                }
                context.stroke(
                    Path(roundedRect: rect(layout.goal, MiniMapLayout.goalSize), cornerRadius: 3),
                    with: .color(TeleopColors.statusGreen), style: StrokeStyle(lineWidth: 2, dash: [5, 4])
                )
                context.fill(
                    Path(roundedRect: rect(layout.cube, MiniMapLayout.cubeSize), cornerRadius: 2),
                    with: .color(TeleopColors.emergency)
                )
                // The ring is a little wider than the cube, like open jaws around it.
                // The ring is where the jaws pinch. It is a little wider than the cube, like open jaws around it,
                // and turns green when closing now would take hold.
                let jaws: Color = guidance.readyToGrasp ? TeleopColors.statusGreen : .white
                let ring = rect(layout.arm, MiniMapLayout.cubeSize * 1.9)
                context.stroke(Path(ellipseIn: ring), with: .color(jaws), lineWidth: guidance.readyToGrasp ? 4 : 2.5)
                context.fill(Path(ellipseIn: CGRect(x: ring.midX - 2, y: ring.midY - 2, width: 4, height: 4)), with: .color(jaws))
            }
            .frame(width: side, height: side)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.25), lineWidth: 1))

            Canvas { context, size in
                let height = Float(size.height)
                let mid = size.width / 2
                context.stroke(
                    Path { $0.move(to: CGPoint(x: mid, y: 0)); $0.addLine(to: CGPoint(x: mid, y: size.height)) },
                    with: .color(.white.opacity(0.3)), lineWidth: 2
                )
                let cubeY = CGFloat(layout.barOffset(layout.cube.z, height: height))
                context.fill(Path(CGRect(x: mid - 6, y: cubeY - 5, width: 12, height: 10)), with: .color(TeleopColors.emergency))
                let armY = CGFloat(layout.barOffset(layout.arm.z, height: height))
                context.stroke(
                    Path(ellipseIn: CGRect(x: mid - 8, y: armY - 8, width: 16, height: 16)),
                    with: .color(guidance.readyToGrasp ? TeleopColors.statusGreen : .white), lineWidth: 2.5
                )
            }
            .frame(width: barWidth, height: side)
        }
        .accessibilityIdentifier("guide.map")
    }
}

struct ServerAddressField: View {
    let address: String
    let error: Bool

    var body: some View {
        Text(address)
            .font(.system(size: 16, design: .monospaced))
            .foregroundStyle(TeleopColors.textPrimary)
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
