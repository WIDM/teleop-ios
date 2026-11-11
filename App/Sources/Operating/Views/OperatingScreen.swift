import SwiftUI
import TeleopCore
import UIKit

/// The one control screen (§7.2), in the phone modes and in buttons mode. It draws `model.operating` and nothing else.
///
/// One `TouchSurfaceView` covers the whole screen, safe areas included, and every touch on it goes to the model with
/// its own timestamp. Everything drawn above it lets touches through, so the bands, the gear and the control surface
/// are judged by the input rules; the zones are drawn from the same `SurfaceLayout` the rules judge with. Only the
/// button pad and the release button take their own touches.
struct OperatingScreen: View {
    let model: AppModel
    @Environment(\.surfaceInsets) private var insetsOverride

    var body: some View {
        // The outer reader keeps to the safe area, so it knows the insets; the inner one covers the whole screen.
        GeometryReader { safe in
            GeometryReader { proxy in
                let insets = insetsOverride ?? SurfaceInsets(top: safe.safeAreaInsets.top, bottom: safe.safeAreaInsets.bottom)
                let surface = SurfaceSize(width: proxy.size.width, height: proxy.size.height, insets: insets)
                OperatingSurface(model: model, display: model.operating, surface: surface)
                    .onAppear { report(surface) }
                    .onChange(of: surface) { _, new in report(new) }
            }
            .ignoresSafeArea()
        }
        .defersSystemGestures(on: .vertical)
        .volumeKeys(model: model, enabled: model.operating.mode != .buttons)
        // The screen stays awake while it shows: it is held, not looked at.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func report(_ surface: SurfaceSize) {
        model.surfaceChanged(
            width: surface.width, height: surface.height, safeTop: surface.insets.top, safeBottom: surface.insets.bottom
        )
    }
}

struct SurfaceInsets: Equatable {
    var top: Double
    var bottom: Double
}

private struct SurfaceInsetsKey: EnvironmentKey {
    static let defaultValue: SurfaceInsets? = nil
}

extension EnvironmentValues {
    /// Set only when the app is drawn in a smaller frame than the device (UI tests at 667 pt): the safe-area
    /// insets that frame stands for.
    var surfaceInsets: SurfaceInsets? {
        get { self[SurfaceInsetsKey.self] }
        set { self[SurfaceInsetsKey.self] = newValue }
    }
}

struct SurfaceSize: Equatable {
    var width: Double
    var height: Double
    var insets: SurfaceInsets

    /// The zones before the model has reported its own, from the same inputs, so the first frame is already right.
    var layout: SurfaceLayout {
        SurfaceLayout(width: width, height: height, safeTop: insets.top, safeBottom: insets.bottom)
    }
}

private struct OperatingSurface: View {
    let model: AppModel
    let display: OperatingDisplay
    let surface: SurfaceSize

    var body: some View {
        let layout = display.layout ?? surface.layout
        let look = OperatingWords.look(display)
        let scale = layout.height / 874
        ZStack(alignment: .topLeading) {
            ZoneFills(layout: layout, colour: look.colour, practice: display.practice)
            TouchLayer { sample, time in model.touch(sample, at: time) }
            OperatingDrawing(display: display, layout: layout, look: look, scale: scale, profile: model.profile)
                .allowsHitTesting(false)
        }
        .overlayPreferenceValue(StateWordsBounds.self) { words in
            GeometryReader { proxy in
                OperatingControls(
                    model: model, display: display, layout: layout, scale: scale, words: words.map { proxy[$0] }
                )
            }
        }
        .frame(width: layout.width, height: layout.height, alignment: .topLeading)
    }
}

/// Where the state word and its detail lines are drawn, so the not-connected word can open Connect (§7.2).
private struct StateWordsBounds: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

extension View {
    /// Puts the view exactly on a zone rectangle, in the operating screen's coordinates.
    func place(_ rect: SurfaceLayout.Rect) -> some View {
        frame(width: max(0, rect.width), height: max(0, rect.height)).offset(x: rect.x, y: rect.y)
    }
}

/// The bands, the gap and the control surface in their colours. Practice lays purple stripes over every state.
private struct ZoneFills: View {
    let layout: SurfaceLayout
    let colour: Color
    let practice: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            TeleopColors.band.place(layout.topBand)
            colour.place(layout.controlSurface)
            TeleopColors.band.place(layout.gap)
            TeleopColors.emergency.place(layout.bottomBand)
            if practice {
                PracticeStripes()
                    .place(SurfaceLayout.Rect(x: 0, y: 0, width: layout.width, height: layout.gap.y))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Purple diagonal stripes: practice can never be taken for the real thing (§7.4).
struct PracticeStripes: View {
    var body: some View {
        Canvas { context, size in
            let step = 34.0
            var x = -size.height
            while x < size.width {
                context.stroke(
                    Path { $0.move(to: CGPoint(x: x, y: size.height)); $0.addLine(to: CGPoint(x: x + size.height, y: 0)) },
                    with: .color(TeleopColors.practice.opacity(0.45)), lineWidth: 12
                )
                x += step
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The practice mark above the state word, in both languages for anyone looking on.
struct PracticeMark: View {
    var size: Double = 16

    var body: some View {
        Text("state.practice")
            .font(.system(size: size, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(TeleopColors.practice, in: Capsule())
            .accessibilityIdentifier("practice.mark")
    }
}

/// The touch surface: a plain UIKit view so every raw touch keeps its radius and timestamp.
private struct TouchLayer: UIViewRepresentable {
    let onTouch: (TouchSample, TimeInterval) -> Void

    func makeUIView(context: Context) -> TouchSurfaceView {
        let view = TouchSurfaceView()
        view.onTouch = onTouch
        return view
    }

    func updateUIView(_ view: TouchSurfaceView, context: Context) {
        view.onTouch = onTouch
    }
}

/// Everything drawn over the touch surface. It takes no touches (the caller turns hit testing off), but each part a
/// person or a test needs to find is an accessibility element.
private struct OperatingDrawing: View {
    let display: OperatingDisplay
    let layout: SurfaceLayout
    let look: OperatingWords.Look
    let scale: Double
    let profile: RobotProfile

    var body: some View {
        ZStack(alignment: .topLeading) {
            TopBand(display: display, layout: layout, scale: scale)
            if display.mode == .buttons {
                ButtonsStrip(display: display, look: look, scale: scale)
                    .place(Self.strip(display, layout: layout, scale: scale))
            } else {
                PhoneSurface(display: display, layout: layout, look: look, scale: scale, profile: profile)
                    .place(layout.controlSurface)
            }
            // The label sits in the band's part above the home indicator.
            let constants = InputConstants.appendixA
            BottomBandLabel(scale: scale)
                .place(SurfaceLayout.Rect(
                    x: 0, y: layout.bottomBand.y, width: layout.width,
                    height: constants.bottomBandPt * layout.height / constants.referenceHeightPt
                ))
        }
    }

    /// Buttons mode: the state strip at the top of the control surface (§3.2), taller while stopped so the cause,
    /// the reset prompt and the release button fit.
    static func strip(_ display: OperatingDisplay, layout: SurfaceLayout, scale: Double) -> SurfaceLayout.Rect {
        var height = 96 * scale
        if display.practice { height += 24 * scale }
        if case .stopped = display.state {
            height += 34 * scale
            if display.stopExits.recordingMayStayOff, OperatingWords.offersRelease(display) { height += 44 * scale }
            if OperatingWords.offersRelease(display) { height += ReleaseButton.height(scale) + 12 * scale }
        }
        let cs = layout.controlSurface
        return SurfaceLayout.Rect(x: cs.x, y: cs.y, width: cs.width, height: min(height, cs.height))
    }
}

/// Top band: the gear, the REC line, the link dot, the mode chip, the reset hint, and the countdown while the band is
/// held toward a reset.
private struct TopBand: View {
    let display: OperatingDisplay
    let layout: SurfaceLayout
    let scale: Double

    var body: some View {
        let gear = layout.gear
        let safeTop = gear.y - (layout.topBand.maxY - gear.y - gear.height)
        let row = SurfaceLayout.Rect(
            x: gear.maxX + 4, y: max(0, safeTop), width: layout.width - gear.maxX - 16,
            height: layout.topBand.maxY - max(0, safeTop)
        )
        ZStack(alignment: .topLeading) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: max(20, 26 * scale)))
                .foregroundStyle(.white)
                .place(gear)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("control.settings"))
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("operating.gear")
            VStack(alignment: .center, spacing: 3 * scale) {
                RecLineView(line: OperatingWords.recLine(display), scale: scale)
                HStack(spacing: 8) {
                    Text("band.reset_hint")
                        .font(.system(size: max(11, 12 * scale)))
                        .foregroundStyle(TeleopColors.bandText)
                        .accessibilityIdentifier("operating.reset_hint")
                    Spacer(minLength: 4)
                    LinkDotView(dot: OperatingWords.linkDot(display))
                    Text(verbatim: OperatingWords.modeChip(display.mode))
                        .font(.system(size: max(12, 14 * scale), weight: .bold))
                        .foregroundStyle(TeleopColors.band)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.white, in: Capsule())
                        .accessibilityLabel(Text(verbatim: OperatingWords.modeName(display.mode)))
                        .accessibilityIdentifier("operating.mode")
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .place(row)
            if let countdown = display.resetCountdown {
                let bar = SurfaceLayout.Rect(x: 0, y: layout.topBand.maxY - 6 * scale, width: layout.width * min(max(countdown, 0), 1), height: 6 * scale)
                TeleopColors.statusAmber
                    .place(bar)
                    .accessibilityElement()
                    .accessibilityLabel(Text("band.reset_hint"))
                    .accessibilityValue(Text(verbatim: "\(Int((countdown * 100).rounded()))%"))
                    .accessibilityIdentifier("operating.countdown")
            }
        }
    }
}

private struct RecLineView: View {
    let line: OperatingWords.RecLine?
    let scale: Double

    var body: some View {
        if let line {
            let size = max(12, 14 * scale)
            HStack(spacing: 5) {
                if let dot = line.dot {
                    Circle()
                        .fill(dot == .capturing ? TeleopColors.emergency : TeleopColors.bandText)
                        .frame(width: 9, height: 9)
                }
                (Text(verbatim: line.text)
                    + Text(verbatim: line.elapsed.map { " " + $0 } ?? "").font(.system(size: size * 0.8, weight: .regular).monospacedDigit())
                    + Text(verbatim: line.tail.map { " " + $0 } ?? ""))
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(line.warning ? TeleopColors.statusAmber : .white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: line.spoken))
            .accessibilityIdentifier("operating.rec")
        } else {
            // Keeps the row's height when the server has not said whether it records.
            Text(verbatim: " ").font(.system(size: max(12, 14 * scale))).accessibilityHidden(true)
        }
    }
}

private struct LinkDotView: View {
    let dot: OperatingWords.LinkDot

    var body: some View {
        Group {
            switch dot {
            case .practice:
                Circle().strokeBorder(.white, lineWidth: 2)
            case .up:
                Circle().fill(TeleopColors.statusGreen)
            case .slow:
                Circle().fill(TeleopColors.statusAmber)
            case .down:
                Circle().fill(TeleopColors.bandText)
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: OperatingWords.linkLabel(dot)))
        .accessibilityIdentifier("operating.link")
    }
}

/// The state word and its detail lines, centred.
private struct StateWords: View {
    let look: OperatingWords.Look
    let practice: Bool
    let wordSize: Double
    let detailSize: Double

    var body: some View {
        VStack(spacing: 4) {
            if practice { PracticeMark(size: max(12, detailSize * 0.8)) }
            Text(verbatim: look.word)
                .font(.system(size: wordSize, weight: .bold))
                .accessibilityIdentifier("operating.state")
            ForEach(Array(look.details.enumerated()), id: \.offset) { _, detail in
                Text(verbatim: detail)
                    .font(.system(size: detailSize, weight: .medium))
                    .accessibilityIdentifier("operating.detail")
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(look.darkText ? TeleopColors.textPrimary : .white)
        .anchorPreference(key: StateWordsBounds.self, value: .bounds) { $0 }
    }
}

/// The phone modes' control surface: the state, the guide, and the scheme's faint hints.
private struct PhoneSurface: View {
    let display: OperatingDisplay
    let layout: SurfaceLayout
    let look: OperatingWords.Look
    let scale: Double
    let profile: RobotProfile

    /// Smaller than §7.2's 56 pt, so the guide has room under it.
    static func wordSize(_ scale: Double) -> Double { max(30, 44 * scale) }

    /// The faint hints: dark on gold, as the state words are.
    static func hintInk(_ look: OperatingWords.Look) -> Color {
        look.darkText ? TeleopColors.textPrimary.opacity(0.75) : .white.opacity(0.7)
    }

    var body: some View {
        let stopped = { if case .stopped = display.state { return true } else { return false } }()
        ZStack(alignment: .top) {
            if display.mode == .keyTurns, !stopped {
                SchemeBHints(display: display, layout: layout, scale: scale, ink: Self.hintInk(look))
            }
            VStack(spacing: 8 * scale) {
                StateWords(look: look, practice: display.practice, wordSize: Self.wordSize(scale), detailSize: max(15, 20 * scale))
                if display.taskAid, let arm = display.arm {
                    GuideView(picture: GuidePicture(reading: arm, profile: profile), scale: scale)
                } else {
                    Spacer(minLength: 0)
                }
                if OperatingWords.offersRelease(display) {
                    Color.clear.frame(height: ReleaseButton.height(scale))
                } else if display.mode == .screenTurns, !stopped {
                    Text("hint.scheme_a")
                        .font(.system(size: max(12, 14 * scale), weight: .medium))
                        .foregroundStyle(Self.hintInk(look))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("operating.hint")
                } else if display.mode == .keyTurns, !stopped {
                    Color.clear.frame(height: max(14, 18 * scale))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10 * scale)
        }
    }
}

/// Scheme B: a faint band down the middle, and which half opens and which closes, at the lower corners.
private struct SchemeBHints: View {
    let display: OperatingDisplay
    let layout: SurfaceLayout
    let scale: Double
    let ink: Color

    var body: some View {
        let cs = layout.controlSurface
        let nearIsRight = display.hand == .right
        ZStack(alignment: .bottom) {
            Color.white.opacity(0.10)
                .frame(width: layout.sideDeadPt * 2)
                .frame(maxHeight: .infinity)
                .accessibilityHidden(true)
            HStack {
                hint(nearIsRight ? "hint.open" : "hint.close", id: nearIsRight ? "operating.hint_open" : "operating.hint_close")
                Spacer()
                hint(nearIsRight ? "hint.close" : "hint.open", id: nearIsRight ? "operating.hint_close" : "operating.hint_open")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10 * scale)
        }
        .frame(width: cs.width, height: cs.height)
    }

    private func hint(_ key: LocalizedStringKey, id: String) -> some View {
        Text(key)
            .font(.system(size: max(13, 16 * scale), weight: .semibold))
            .foregroundStyle(ink)
            .accessibilityIdentifier(id)
    }
}

/// Buttons mode: the state shrinks to a strip over the pad (§3.2).
private struct ButtonsStrip: View {
    let display: OperatingDisplay
    let look: OperatingWords.Look
    let scale: Double

    var body: some View {
        VStack(spacing: 6 * scale) {
            StateWords(look: look, practice: display.practice, wordSize: max(24, 34 * scale), detailSize: max(13, 16 * scale))
            Spacer(minLength: 0)
            if OperatingWords.offersRelease(display) {
                Color.clear.frame(height: ReleaseButton.height(scale))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8 * scale)
    }
}

/// STOP 急停, always, in both languages for anyone looking on.
private struct BottomBandLabel: View {
    let scale: Double

    var body: some View {
        Text("band.stop")
            .font(.system(size: max(20, 26 * scale), weight: .heavy))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("band.stop"))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("operating.stop")
    }
}

/// The controls that take their own touches: the button pad in buttons mode, the release button in the stopped
/// state when the stop exits offer it, and the not-connected word, which opens Connect (§7.2).
private struct OperatingControls: View {
    let model: AppModel
    let display: OperatingDisplay
    let layout: SurfaceLayout
    let scale: Double
    /// Where the state words are drawn, in this view's coordinates.
    let words: CGRect?

    var body: some View {
        let cs = layout.controlSurface
        ZStack(alignment: .topLeading) {
            if case .notConnected = display.state, let words {
                // With no link every other touch is refused, so the word is the one thing worth tapping.
                let height = max(60, words.height + 16)
                Button { model.send(.changeServer) } label: { Color.clear.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("detail.tap_to_connect"))
                    .accessibilityIdentifier("operating.connect")
                    .place(SurfaceLayout.Rect(x: cs.x + 16, y: words.midY - height / 2, width: cs.width - 32, height: height))
            }
            if display.mode == .buttons {
                let strip = OperatingDrawing.strip(display, layout: layout, scale: scale)
                ButtonPadView(
                    held: display.heldButton, speed: display.speed, nearSideIsRight: display.hand == .right,
                    onTouchDown: { model.buttonDown($0) },
                    onTouchUp: { model.buttonUp($0) },
                    onDragOut: { model.buttonUp($0) },
                    onSpeed: { model.selectSpeed($0) }
                )
                .place(SurfaceLayout.Rect(x: cs.x, y: strip.maxY, width: cs.width, height: cs.maxY - strip.maxY))
                if OperatingWords.offersRelease(display) {
                    ReleaseButton(scale: scale) { model.send(.releaseStop) }
                        .place(SurfaceLayout.Rect(
                            x: cs.x + 16, y: strip.maxY - 8 * scale - ReleaseButton.height(scale),
                            width: cs.width - 32, height: ReleaseButton.height(scale)
                        ))
                }
            } else if OperatingWords.offersRelease(display) {
                ReleaseButton(scale: scale) { model.send(.releaseStop) }
                    .place(SurfaceLayout.Rect(
                        x: cs.x + 16, y: cs.maxY - 10 * scale - ReleaseButton.height(scale),
                        width: cs.width - 32, height: ReleaseButton.height(scale)
                    ))
            }
        }
    }
}

/// **Release, keep scene**: a one-second hold that releases the stop and leaves the scene as it is (§6.5).
private struct ReleaseButton: View {
    let scale: Double
    let action: () -> Void

    /// A hold the operator needs while stopped: never under 60 pt.
    static func height(_ scale: Double) -> Double { max(60, 60 * scale) }

    var body: some View {
        HoldButton(
            titleKey: "btn.release_keep_scene",
            fill: TeleopColors.card,
            border: TeleopColors.textSecondary.opacity(0.25),
            borderWidth: 1,
            foreground: TeleopColors.textPrimary,
            progress: TeleopColors.statusAmber.opacity(0.35),
            height: Self.height(scale),
            action: action
        )
        .accessibilityIdentifier("stop.release")
    }
}
