import SwiftUI
import TeleopCore

struct StopButton: View {
    var accessibilityId = "stop"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                Text("stop.label").font(.system(size: 22, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: TeleopMetrics.stopHeight)
            .background(TeleopColors.emergency, in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
            .overlay(
                RoundedRectangle(cornerRadius: TeleopMetrics.corner)
                    .strokeBorder(TeleopColors.emergencyBorder, lineWidth: 3)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityId)
    }
}

struct FilledButtonStyle: ButtonStyle {
    var color: Color = TeleopColors.primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: TeleopMetrics.touch)
            .background(color, in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct OutlineButtonStyle: ButtonStyle {
    var color: Color = TeleopColors.textPrimary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, minHeight: TeleopMetrics.touch)
            .background(TeleopColors.card, in: RoundedRectangle(cornerRadius: TeleopMetrics.corner))
            .overlay(
                RoundedRectangle(cornerRadius: TeleopMetrics.corner)
                    .strokeBorder(color.opacity(0.4), lineWidth: 1.5)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct TextActionStyle: ButtonStyle {
    var color: Color = TeleopColors.textPrimary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16))
            .foregroundStyle(color)
            .frame(minHeight: TeleopMetrics.touch)
            .padding(.horizontal, 8)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Needs a 1 second press, with a bar that fills while held.
struct HoldButton: View {
    let titleKey: LocalizedStringKey
    var systemImage: String? = nil
    var fill: Color = TeleopColors.emergency
    var border: Color? = nil
    var borderWidth: CGFloat = 3
    var foreground: Color = .white
    var progress: Color = Color.white.opacity(0.35)
    var height: CGFloat = TeleopMetrics.touch
    let action: () -> Void

    @GestureState private var pressing = false

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: TeleopMetrics.corner).fill(fill)
            GeometryReader { proxy in
                Rectangle()
                    .fill(progress)
                    .frame(width: proxy.size.width * (pressing ? 1 : 0))
                    .animation(pressing ? .linear(duration: 1) : .easeOut(duration: 0.15), value: pressing)
            }
            .clipShape(RoundedRectangle(cornerRadius: TeleopMetrics.corner))
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(titleKey).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
        }
        .frame(height: height)
        .overlay(
            RoundedRectangle(cornerRadius: TeleopMetrics.corner)
                .strokeBorder(border ?? .clear, lineWidth: borderWidth)
        )
        .contentShape(RoundedRectangle(cornerRadius: TeleopMetrics.corner))
        .gesture(
            LongPressGesture(minimumDuration: 1)
                .updating($pressing) { value, state, _ in state = value }
                .onEnded { _ in action() }
        )
        .accessibilityAddTraits(.isButton)
    }
}

/// Press = start moving the arm, release = stop. Same session path as holding vol+ (`holdArmStart` / `holdArmEnd`).
/// One press sends one `holdArmStart`, so finger drift cannot repeat a blocked cue or restart an arm that was auto-stopped.
/// `@GestureState` also resets when the system cancels the gesture (call, Control Center), so that sends `holdArmEnd` too.
private struct ArmHoldModifier: ViewModifier {
    let model: AppModel
    @GestureState private var pressing = false
    @State private var startSent = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressing) { _, state, _ in state = true }
                    .onChanged { _ in
                        guard !startSent else { return }
                        startSent = true
                        model.send(.holdArmStart)
                    }
                    .onEnded { _ in
                        startSent = false
                        model.send(.holdArmEnd)
                    }
            )
            .onChange(of: pressing) { _, isPressing in
                guard !isPressing else { return }
                startSent = false
                model.send(.holdArmEnd)
            }
            .onDisappear {
                guard model.session.state.armMoving else { return }
                model.send(.holdArmEnd)
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(model.session.state.armMoving ? "moving" : "stopped")
    }
}

/// Press = start a held control, release = stop it. One press sends `start` once, for the same reasons as the arm hold:
/// finger drift must not repeat a blocked cue. Same session path as the volume keys, so `end` is what releasing sends.
/// A release ends only the hold this control started: another finger may have taken over with a different control,
/// and the session state at release time says whether that happened.
private struct HeldControlModifier: ViewModifier {
    let model: AppModel
    let start: TeleopAction
    let end: TeleopAction
    let isActive: Bool
    @GestureState private var pressing = false
    @State private var startSent = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressing) { _, state, _ in state = true }
                    .onChanged { _ in
                        guard !startSent else { return }
                        startSent = true
                        model.send(start)
                    }
                    .onEnded { _ in
                        startSent = false
                        release()
                    }
            )
            .onChange(of: pressing) { _, isPressing in
                guard !isPressing else { return }
                startSent = false
                release()
            }
            .onDisappear {
                guard isActive else { return }
                model.send(end)
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isActive ? "moving" : "stopped")
    }

    private func release() {
        guard model.session.state.isHolding(start) else { return }
        model.send(end)
    }
}

/// Hold-to-move gripper button for the on-screen controls.
struct GripperHoldButton: View {
    let model: AppModel
    let target: GripperState

    var body: some View {
        let active = model.session.state.gripperMoving == target
        Label(
            target == .open ? "control.gripper_hold_open" : "control.gripper_hold_close",
            systemImage: target == .open ? "arrow.left.and.right" : "arrow.right.and.line.vertical.and.arrow.left"
        )
        .font(.system(size: 16, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .foregroundStyle(TeleopColors.textPrimary)
        .frame(maxWidth: .infinity, minHeight: TeleopMetrics.touch)
        .background(
            active ? TeleopColors.primary.opacity(0.2) : TeleopColors.card,
            in: RoundedRectangle(cornerRadius: TeleopMetrics.corner)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TeleopMetrics.corner)
                .strokeBorder(TeleopColors.textPrimary.opacity(0.4), lineWidth: 1.5)
        )
        // One element for the whole button: iOS 18 otherwise exposes the icon as a second, untappable one.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(target == .open ? "control.gripper_hold_open" : "control.gripper_hold_close"))
        .gripperHold(model: model, target: target)
        .accessibilityIdentifier(target == .open ? "gripper.open" : "gripper.close")
    }
}

/// Left edge of the camera view: hold to open the gripper. Closing is on vol−, so only opening needs the screen.
struct GripperOpenHandle: View {
    let model: AppModel

    var body: some View {
        let active = model.session.state.gripperMoving == .open
        VStack(spacing: 4) {
            Image(systemName: "arrow.left.and.right").font(.system(size: 22))
            Text("control.gripper_open_handle").font(.system(size: 17))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: TeleopMetrics.touch, maxHeight: .infinity)
        .background(
            active ? TeleopColors.primary : TeleopColors.basePanel,
            in: UnevenRoundedRectangle(bottomTrailingRadius: 12, topTrailingRadius: 12)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("control.gripper_open_handle"))
        .gripperHold(model: model, target: .open)
        .accessibilityIdentifier("gripper.open")
    }
}

/// Left edge of the camera view, under the open handle: hold to move the wrist. Two handles roll it, which turns the
/// jaws about the forearm; two tilt it, which points the jaws more toward the table or away from it.
/// One press moves it by up to 45 degrees (roll) or 10 degrees (tilt) and it stays where it is on release.
/// The server reports no wrist angle, so the handle cannot show how far it has moved.
struct JawTurnHandle: View {
    let model: AppModel
    let direction: TurnDirection

    var body: some View {
        let active = model.session.state.jawTurning == direction
        let look = Self.look(direction)
        VStack(spacing: 2) {
            Image(systemName: look.symbol).font(.system(size: 22))
            Text(look.label).font(.system(size: 13))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: TeleopMetrics.touch)
        .background(
            active ? TeleopColors.primary : TeleopColors.basePanel,
            in: UnevenRoundedRectangle(bottomTrailingRadius: 12, topTrailingRadius: 12)
        )
        // One element for the whole handle: iOS 18 otherwise exposes the icon as a second, untappable one.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(look.spoken))
        .turnHold(model: model, direction: direction)
        .accessibilityIdentifier(look.identifier)
    }

    private static func look(_ direction: TurnDirection) -> (symbol: String, label: LocalizedStringKey, spoken: LocalizedStringKey, identifier: String) {
        switch direction {
        case .positive: ("arrow.counterclockwise", "control.jaw_turn", "control.jaw_turn_positive", "jaw.turn_positive")
        case .negative: ("arrow.clockwise", "control.jaw_turn", "control.jaw_turn_negative", "jaw.turn_negative")
        case .tiltDown: ("arrow.down.to.line", "control.jaw_tilt", "control.jaw_tilt_down", "jaw.tilt_down")
        case .tiltUp: ("arrow.up.to.line", "control.jaw_tilt", "control.jaw_tilt_up", "jaw.tilt_up")
        }
    }
}

/// The hold-to-act handles down the left edge of the camera view: open the gripper, turn the jaws each way,
/// tilt them down and up.
struct LeftHandles: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            GripperOpenHandle(model: model)
            JawTurnHandle(model: model, direction: .positive)
            JawTurnHandle(model: model, direction: .negative)
            JawTurnHandle(model: model, direction: .tiltDown)
            JawTurnHandle(model: model, direction: .tiltUp)
        }
    }
}

extension View {
    func armHold(model: AppModel) -> some View {
        modifier(ArmHoldModifier(model: model))
    }

    func gripperHold(model: AppModel, target: GripperState) -> some View {
        modifier(HeldControlModifier(
            model: model, start: .gripperStart(target), end: .gripperEnd,
            isActive: model.session.state.gripperMoving == target
        ))
    }

    func turnHold(model: AppModel, direction: TurnDirection) -> some View {
        modifier(HeldControlModifier(
            model: model, start: .turnStart(direction), end: .turnEnd,
            isActive: model.session.state.jawTurning == direction
        ))
    }
}
