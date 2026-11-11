/// A rectangle in points, origin at the top left.
public struct PadRect: Equatable, Sendable {
    public var x, y, width, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    /// How far a point lies outside this rectangle, in points; 0 inside or on the edge.
    public func distance(toX px: Double, y py: Double) -> Double {
        let dx = max(minX - px, 0, px - maxX)
        let dy = max(minY - py, 0, py - maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// Where the button pad's controls sit (INTERACTION §3.2), from the space the pad is given. The view draws exactly
/// this and the drag-out rule is judged against it, so a button cannot be drawn in one place and judged in another.
///
/// The pad is the move pad (a cross of Forward, Left, Right, Back around a centre cell that shows the speed), the
/// lift column (Up above Down) to its right, the gripper row (Open on the far side, Close on the near side) and the
/// Fine | Coarse switch. Where the §3.2 sizes fit they are used as they are; on a smaller phone everything shrinks
/// by one factor, and no control gets smaller than `minimumTargetPt` either way.
public struct ButtonPadLayout: Equatable, Sendable {
    /// The pad's space on the reference phone (402 × 874 pt): the screen less the top band (62 pt safe area + 64),
    /// the state strip (96), the gap (16) and the bottom band (72 + 34 pt safe area), as §2.2 and §3.2 give them.
    public static let referenceWidth = 402.0
    public static let referenceHeight = 530.0
    public static let minimumTargetPt = 60.0
    /// A finger further than this outside its button has left it, which ends the hold (Appendix A `buttonSlipPt`).
    public static let slipPt = 20.0

    // §3.2 sizes at the reference phone.
    static let crossCell = 88.0
    static let liftWidth = 96.0
    static let liftHeight = 128.0
    static let gripperHeight = 72.0
    static let gap = 16.0
    static let margin = 16.0
    /// The switch is 44 pt in §3.2; the unit brief allows no target under 60 pt, so it is 60 at every size.
    static let speedHeight = 60.0
    /// Narrowest space kept between the cross and the lift column (10 pt at the reference width).
    static let minimumColumnGap = 8.0

    public var buttons: [ButtonID: PadRect]
    /// The centre of the cross. It shows the speed and is not a target.
    public var speedLabel: PadRect
    public var speedSwitch: PadRect
    public var fineSegment: PadRect
    public var coarseSegment: PadRect

    /// - Parameter nearSideIsRight: the holding hand is the right one (Settings → Hand), so Close, the near-side
    ///   gripper button, goes on the right, as in scheme B.
    public static func make(width: Double, height: Double, nearSideIsRight: Bool = true) -> ButtonPadLayout {
        let scale = scale(width: width, height: height)
        let cell = max(minimumTargetPt, crossCell * scale)
        let liftW = max(minimumTargetPt, liftWidth * scale)
        let liftH = max(minimumTargetPt, liftHeight * scale)
        let gripperH = max(minimumTargetPt, gripperHeight * scale)
        let rowGap = gap * scale

        let crossSize = 3 * cell
        let columnHeight = 2 * liftH + rowGap
        let topRow = max(crossSize, columnHeight)
        let content = topRow + rowGap + gripperH + rowGap + speedHeight
        let top = max(0, (height - content) / 2)

        let crossX = margin
        let crossY = top + (topRow - crossSize) / 2
        func cross(_ column: Double, _ row: Double) -> PadRect {
            PadRect(x: crossX + column * cell, y: crossY + row * cell, width: cell, height: cell)
        }
        let liftX = width - margin - liftW
        let liftY = top + (topRow - columnHeight) / 2

        let gripperY = top + topRow + rowGap
        let gripperW = (width - 2 * margin - gap) / 2
        let leftGripper = PadRect(x: margin, y: gripperY, width: gripperW, height: gripperH)
        let rightGripper = PadRect(x: margin + gripperW + gap, y: gripperY, width: gripperW, height: gripperH)

        let speedY = gripperY + gripperH + rowGap
        let speedW = width - 2 * margin
        return ButtonPadLayout(
            buttons: [
                .forward: cross(1, 0),
                .left: cross(0, 1),
                .right: cross(2, 1),
                .back: cross(1, 2),
                .up: PadRect(x: liftX, y: liftY, width: liftW, height: liftH),
                .down: PadRect(x: liftX, y: liftY + liftH + rowGap, width: liftW, height: liftH),
                .open: nearSideIsRight ? leftGripper : rightGripper,
                .close: nearSideIsRight ? rightGripper : leftGripper,
            ],
            speedLabel: cross(1, 1),
            speedSwitch: PadRect(x: margin, y: speedY, width: speedW, height: speedHeight),
            fineSegment: PadRect(x: margin, y: speedY, width: speedW / 2, height: speedHeight),
            coarseSegment: PadRect(x: margin + speedW / 2, y: speedY, width: speedW / 2, height: speedHeight)
        )
    }

    /// The largest factor, at most 1, at which the pad fits. Below about 0.83 the gripper row stays at the minimum
    /// height and only the cross and the lift column keep shrinking.
    static func scale(width: Double, height: Double) -> Double {
        // The lift column (taller than the cross), the gripper row and the gaps between: 376 pt at the reference.
        let scalingHeight = (2 * liftHeight + gap) + gap + gripperHeight + gap
        var scale = min(1, (height - speedHeight) / scalingHeight)
        if gripperHeight * scale < minimumTargetPt {
            scale = (height - speedHeight - minimumTargetPt) / (scalingHeight - gripperHeight)
        }
        let byWidth = (width - 2 * margin - minimumColumnGap) / (3 * crossCell + liftWidth)
        return max(0, min(scale, byWidth))
    }

    /// True when a finger at (x, y), in the pad's coordinates, is more than `slipPt` outside `button`.
    public func hasSlipped(off button: ButtonID, x: Double, y: Double) -> Bool {
        guard let rect = buttons[button] else { return true }
        return rect.distance(toX: x, y: y) > Self.slipPt
    }
}
