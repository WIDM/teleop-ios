/// A-4's slide, judged in one place for the rules that use it: scheme A opening the jaws, and the lock's "hold, then
/// slide up". Travel is the larger of the two components from touch-down, in millimetres. Scheme B's swipe rule (the
/// straight distance from touch-down) is a different rule and does not use it.
public enum ThumbSlide: Equatable, Sendable {
    /// Not yet `openSlideMm` on either axis.
    case short
    /// At least `openSlideMm`, up the glass and more up than sideways.
    case up
    /// At least `openSlideMm`, but down the glass or no more up than sideways.
    case sideways

    public static func judge(
        from down: SIMD2<Double>, to at: SIMD2<Double>, layout: SurfaceLayout, constants: InputConstants
    ) -> ThumbSlide {
        let d = at - down
        let dx = layout.millimetres(d.x), dy = layout.millimetres(d.y)
        guard max(abs(dx), abs(dy)) >= constants.openSlideMm - 1e-9 else { return .short }
        return mostlyUp(dx: dx, dy: dy) ? .up : .sideways
    }

    /// Up the glass and more up than sideways.
    public static func mostlyUp(from down: SIMD2<Double>, to at: SIMD2<Double>) -> Bool {
        let d = at - down
        return mostlyUp(dx: d.x, dy: d.y)
    }

    /// How far up the glass, in millimetres; negative when down.
    public static func upMillimetres(from down: SIMD2<Double>, to at: SIMD2<Double>, layout: SurfaceLayout) -> Double {
        layout.millimetres(down.y - at.y)
    }

    /// Screen y grows downward, so up the glass is negative.
    private static func mostlyUp(dx: Double, dy: Double) -> Bool { dy < 0 && abs(dy) > abs(dx) }
}
