import SwiftUI
import TeleopCore

/// The buttons-mode pad (INTERACTION §3.2): the move pad, the lift column, the gripper row and the Fine / Coarse
/// switch, filling the space it is given between the state strip and the gap above the bottom band. It reports
/// touches and draws what it is told; `ButtonArbiter` decides what a touch means. Every control is placed from
/// `ButtonPadLayout`, the same rectangles that judge a drag-out.
struct ButtonPadView: View {
    /// The button whose hold runs now, drawn as held.
    let held: ButtonID?
    let speed: ButtonSpeed
    /// Settings → Hand is Right: Close, the near-side gripper button, goes on the right.
    var nearSideIsRight = true
    /// A finger came down on the button.
    let onTouchDown: (ButtonID) -> Void
    /// The finger lifted, the system cancelled the touch, or the pad went away under the finger.
    let onTouchUp: (ButtonID) -> Void
    /// The finger moved more than `ButtonPadLayout.slipPt` outside the button. Its touch-up still follows.
    let onDragOut: (ButtonID) -> Void
    /// One side of the Fine | Coarse switch was tapped.
    let onSpeed: (ButtonSpeed) -> Void

    static let space = "buttonPad"

    var body: some View {
        GeometryReader { proxy in
            let layout = ButtonPadLayout.make(
                width: proxy.size.width, height: proxy.size.height, nearSideIsRight: nearSideIsRight
            )
            ZStack(alignment: .topLeading) {
                ForEach(ButtonID.allCases, id: \.self) { button in
                    PadHoldButton(
                        button: button, layout: layout, isHeld: held == button,
                        onTouchDown: onTouchDown, onTouchUp: onTouchUp, onDragOut: onDragOut
                    )
                }
                Self.speedName(speed)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TeleopColors.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: layout.speedLabel.width, height: layout.speedLabel.height)
                    .position(x: layout.speedLabel.midX, y: layout.speedLabel.midY)
                    // The switch already says the speed.
                    .accessibilityHidden(true)
                SpeedSwitch(layout: layout, speed: speed, onSpeed: onSpeed)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .coordinateSpace(.named(Self.space))
        }
    }

    static func speedName(_ speed: ButtonSpeed) -> Text {
        switch speed {
        case .fine: return Text("btn.fine", tableName: "Buttons")
        case .coarse: return Text("btn.coarse", tableName: "Buttons")
        }
    }
}

/// One hold button. A touch reports down once, drag-out at most once, and up once, whatever the system does to it.
private struct PadHoldButton: View {
    let button: ButtonID
    let layout: ButtonPadLayout
    let isHeld: Bool
    let onTouchDown: (ButtonID) -> Void
    let onTouchUp: (ButtonID) -> Void
    let onDragOut: (ButtonID) -> Void

    @GestureState private var pressing = false
    @State private var touching = false
    @State private var slipped = false

    var body: some View {
        let rect = layout.buttons[button] ?? PadRect(x: 0, y: 0, width: 0, height: 0)
        let look = Self.look(button)
        VStack(spacing: 6) {
            Image(systemName: look.symbol).font(.system(size: 24, weight: .semibold))
            look.label
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 4)
        .foregroundStyle(isHeld ? Color.white : TeleopColors.textPrimary)
        .frame(width: rect.width, height: rect.height)
        .background(
            isHeld ? TeleopColors.primary : TeleopColors.card,
            in: RoundedRectangle(cornerRadius: TeleopMetrics.corner)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TeleopMetrics.corner)
                .strokeBorder(TeleopColors.textPrimary.opacity(isHeld ? 0 : 0.4), lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: TeleopMetrics.corner))
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(ButtonPadView.space))
                .updating($pressing) { _, state, _ in state = true }
                .onChanged { value in
                    if !touching {
                        touching = true
                        slipped = false
                        onTouchDown(button)
                    }
                    if !slipped, layout.hasSlipped(off: button, x: value.location.x, y: value.location.y) {
                        slipped = true
                        onDragOut(button)
                    }
                }
                .onEnded { _ in lift() }
        )
        // The gesture state also resets when the system cancels the touch (a call, Control Center).
        .onChange(of: pressing) { _, isPressing in
            if !isPressing { lift() }
        }
        .onDisappear { lift() }
        // One element per button: iOS 18 otherwise exposes the icon as a second, untappable one.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(look.label)
        .accessibilityAddTraits(isHeld ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(look.identifier)
        .position(x: rect.midX, y: rect.midY)
    }

    private func lift() {
        guard touching else { return }
        touching = false
        onTouchUp(button)
    }

    private static func look(_ button: ButtonID) -> (symbol: String, label: Text, identifier: String) {
        switch button {
        case .forward: ("arrow.up", Text("btn.forward", tableName: "Buttons"), "buttons.forward")
        case .back: ("arrow.down", Text("btn.back", tableName: "Buttons"), "buttons.back")
        case .left: ("arrow.left", Text("btn.left", tableName: "Buttons"), "buttons.left")
        case .right: ("arrow.right", Text("btn.right", tableName: "Buttons"), "buttons.right")
        case .up: ("arrow.up.to.line", Text("btn.up", tableName: "Buttons"), "buttons.up")
        case .down: ("arrow.down.to.line", Text("btn.down", tableName: "Buttons"), "buttons.down")
        case .open: ("arrow.left.and.right", Text("btn.open", tableName: "Buttons"), "buttons.open")
        case .close:
            ("arrow.right.and.line.vertical.and.arrow.left", Text("btn.close", tableName: "Buttons"), "buttons.close")
        }
    }
}

/// The segmented Fine | Coarse switch. It reports the side tapped; whether the speed changes is the arbiter's call.
private struct SpeedSwitch: View {
    let layout: ButtonPadLayout
    let speed: ButtonSpeed
    let onSpeed: (ButtonSpeed) -> Void

    var body: some View {
        let rect = layout.speedSwitch
        HStack(spacing: 0) {
            segment(.fine)
            segment(.coarse)
        }
        .frame(width: rect.width, height: rect.height)
        .background(TeleopColors.gripperCard, in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ButtonPadView.speedName(speed))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSpeed(speed == .fine ? .coarse : .fine) }
        .accessibilityAdjustableAction { direction in
            onSpeed(direction == .increment ? .coarse : .fine)
        }
        // The middle of the switch is the seam between the halves. Activating it, or a UI test's tap(), lands on
        // the other half instead, so it toggles as the action above does.
        .accessibilityActivationPoint(UnitPoint(x: speed == .fine ? 0.75 : 0.25, y: 0.5))
        .accessibilityIdentifier("buttons.speed")
        .position(x: rect.midX, y: rect.midY)
    }

    /// Each half answers taps over its full size; the selected fill is inset inside it.
    private func segment(_ choice: ButtonSpeed) -> some View {
        let selected = choice == speed
        return ButtonPadView.speedName(choice)
            .font(.system(size: 17, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(selected ? Color.white : TeleopColors.textPrimary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: TeleopMetrics.corner - 3)
                    .fill(selected ? TeleopColors.primary : Color.clear)
                    .padding(3)
            )
            .contentShape(Rectangle())
            .onTapGesture { onSpeed(choice) }
    }
}
