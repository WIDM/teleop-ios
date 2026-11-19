import TeleopCore

/// Fixed slots within the control surface. Readings and cue text cannot move the guide under a finger.
struct GuideLayout {
    let practice: SurfaceLayout.Rect?
    let word: SurfaceLayout.Rect
    let detail: SurfaceLayout.Rect
    let above: SurfaceLayout.Rect
    let behind: SurfaceLayout.Rect
    let readout: SurfaceLayout.Rect
    let hint: SurfaceLayout.Rect

    init(
        surface: SurfaceLayout, aboveAspect: Double, behindAspect: Double, practice: Bool, footerHeight: Double = 0
    ) {
        let scale = surface.height / 874
        let contentWidth = max(0, surface.width - 32)
        let surfaceHeight = max(0, surface.controlSurface.height - footerHeight)
        let practiceHeight = practice ? max(18, 22 * scale) : 0
        let top = 10 * scale
        self.practice =
            practice
            ? .init(x: 16, y: top, width: contentWidth, height: practiceHeight)
            : nil
        word = .init(x: 16, y: top + practiceHeight, width: contentWidth, height: max(30, 44 * scale) * 1.194)
        detail = .init(x: 16, y: word.maxY + 4, width: contentWidth, height: max(15, 20 * scale) * 1.194)
        let hintHeight = max(14, 18 * scale)
        hint = .init(x: 16, y: surfaceHeight - top - hintHeight, width: contentWidth, height: hintHeight)

        let readoutHeight = 3 * max(13, 15 * scale) * 1.45 + (footerHeight > 0 ? 0 : 8)
        let gap = 6.0
        let viewTop = detail.maxY + 8 * scale
        let room = hint.y - 8 * scale - viewTop - readoutHeight - 2 * gap
        let heightPerWidth = 1 / aboveAspect + 1 / behindAspect
        let width = max(0, min(surface.width - 112, room / heightPerWidth))
        let x = (surface.width - width) / 2
        above = .init(x: x, y: viewTop, width: width, height: width / aboveAspect)
        behind = .init(x: x, y: above.maxY + gap, width: width, height: width / behindAspect)
        readout = .init(x: 16, y: behind.maxY + gap, width: contentWidth, height: readoutHeight)
    }
}
