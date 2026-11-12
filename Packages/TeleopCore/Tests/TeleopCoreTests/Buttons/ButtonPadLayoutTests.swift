import XCTest
@testable import TeleopCore

final class ButtonPadLayoutTests: XCTestCase {
    private let reference = ButtonPadLayout.make(
        width: ButtonPadLayout.referenceWidth, height: ButtonPadLayout.referenceHeight
    )

    /// The pad's height on a phone: the screen less the top band (safe area + 64), the state strip (96), the gap
    /// (16) and the bottom band (72 + safe area), as §2.2 and §3.2 give them.
    private func padHeight(screen: Double, safeTop: Double, safeBottom: Double) -> Double {
        screen - (safeTop + 64) - 96 - 16 - (72 + safeBottom)
    }

    func testTheReferenceHeightIsThe874PointPhonesPadSpace() {
        XCTAssertEqual(padHeight(screen: 874, safeTop: 62, safeBottom: 34), ButtonPadLayout.referenceHeight)
    }

    // MARK: §3.2 at the reference phone

    func testTheReferencePhoneGetsTheSpecifiedSizes() {
        for button in [ButtonID.forward, .back, .left, .right] {
            let rect = reference.buttons[button]!
            XCTAssertEqual(rect.width, 88, "\(button)")
            XCTAssertEqual(rect.height, 88, "\(button)")
        }
        let up = reference.buttons[.up]!, down = reference.buttons[.down]!
        XCTAssertEqual([up.width, up.height, down.width, down.height], [96, 128, 96, 128])
        XCTAssertEqual(down.minY - up.maxY, 16, accuracy: 1e-9, "16 pt between Up and Down")
        for button in [ButtonID.open, .close] {
            let rect = reference.buttons[button]!
            XCTAssertEqual(rect.width, (402 - 48) / 2, "\(button)")
            XCTAssertEqual(rect.height, 72, "\(button)")
        }
        XCTAssertEqual(reference.speedLabel.width, 88)
        XCTAssertEqual(reference.speedLabel.height, 88)
        XCTAssertEqual(reference.speedSwitch.height, 60, "44 pt in §3.2, raised to the brief's 60 pt minimum")
        XCTAssertEqual(reference.speedSwitch.width, 402 - 32)
    }

    func testTheControlsSitWhereSection32PutsThem() {
        let b = reference.buttons
        let centre = reference.speedLabel
        XCTAssertEqual(b[.forward]!.maxY, centre.minY, accuracy: 1e-9)
        XCTAssertEqual(b[.back]!.minY, centre.maxY, accuracy: 1e-9)
        XCTAssertEqual(b[.left]!.maxX, centre.minX, accuracy: 1e-9)
        XCTAssertEqual(b[.right]!.minX, centre.maxX, accuracy: 1e-9)
        XCTAssertEqual(b[.forward]!.midX, centre.midX, accuracy: 1e-9)
        XCTAssertEqual(b[.left]!.midY, centre.midY, accuracy: 1e-9)

        XCTAssertGreaterThan(b[.up]!.minX, b[.right]!.maxX, "the lift column is right of the move pad")
        XCTAssertLessThan(b[.up]!.maxY, b[.down]!.minY, "Up above Down")
        let topRowBottom = max(b[.back]!.maxY, b[.down]!.maxY)
        XCTAssertGreaterThan(b[.open]!.minY, topRowBottom, "the gripper row is under the pads")
        XCTAssertGreaterThan(reference.speedSwitch.minY, b[.open]!.maxY, "the speed switch is under the gripper row")
        XCTAssertEqual(reference.fineSegment.maxX, reference.coarseSegment.minX, accuracy: 1e-9)
        XCTAssertLessThan(reference.fineSegment.minX, reference.coarseSegment.minX, "Fine | Coarse")
    }

    func testCloseIsOnTheNearSideOfTheHoldingHand() {
        XCTAssertGreaterThan(
            reference.buttons[.close]!.minX, reference.buttons[.open]!.minX, "right hand: Close on the right")
        let left = ButtonPadLayout.make(width: 402, height: 530, nearSideIsRight: false)
        XCTAssertLessThan(left.buttons[.close]!.minX, left.buttons[.open]!.minX, "left hand: Close on the left")
        XCTAssertEqual(left.buttons[.forward], reference.buttons[.forward], "only the gripper row follows the hand")
    }

    // MARK: Every phone

    func testNoTargetIsUnder60PointsNoneOverlapAndAllFit() {
        var sizes: [(Double, Double)] = [
            (402, 530),  // reference
            (375, padHeight(screen: 667, safeTop: 20, safeBottom: 0)),  // iPhone SE, 667 pt
            (375, padHeight(screen: 812, safeTop: 50, safeBottom: 34)),  // mini
            (390, padHeight(screen: 844, safeTop: 47, safeBottom: 34)),
            (440, padHeight(screen: 956, safeTop: 62, safeBottom: 34)),  // Pro Max
        ]
        // Down to 320 pt wide (Display Zoom) and to the smallest pad height at which everything fits.
        for width in stride(from: 320.0, through: 440, by: 5) {
            for height in stride(from: 322.0, through: 720, by: 7) { sizes.append((width, height)) }
            sizes.append((width, smallestFittingHeight))
        }
        for (width, height) in sizes {
            for hand in [true, false] {
                let layout = ButtonPadLayout.make(width: width, height: height, nearSideIsRight: hand)
                let context = "\(width) × \(height)"
                let targets = Array(layout.buttons.values) + [layout.fineSegment, layout.coarseSegment]
                XCTAssertEqual(layout.buttons.count, ButtonID.allCases.count, context)
                for rect in targets {
                    XCTAssertGreaterThanOrEqual(rect.width, 60 - 1e-9, context)
                    XCTAssertGreaterThanOrEqual(rect.height, 60 - 1e-9, context)
                }
                for rect in targets + [layout.speedLabel] {
                    XCTAssertGreaterThanOrEqual(rect.minX, 0, context)
                    XCTAssertGreaterThanOrEqual(rect.minY, -1e-9, context)
                    XCTAssertLessThanOrEqual(rect.maxX, width + 1e-9, context)
                    XCTAssertLessThanOrEqual(rect.maxY, height + 1e-9, context)
                }
                let drawn = Array(layout.buttons.values) + [layout.speedLabel, layout.speedSwitch]
                for i in drawn.indices {
                    for j in drawn.indices where j > i {
                        XCTAssertFalse(overlap(drawn[i], drawn[j]), "\(context): \(drawn[i]) and \(drawn[j])")
                    }
                }
            }
        }
    }

    /// Once the lift column is shorter than three 60 pt cross cells, the cells set the top row: 60 + 60 for the
    /// gripper row and the switch, plus the column and gaps (304 pt at full size) at the factor where the column is
    /// 180 pt. About 321 pt.
    private let smallestFittingHeight = 120 + 304 * (180.0 / 272)

    /// Below that the controls cannot all fit (iPhone SE with Display Zoom: 320 × 568 pt, a 300 pt pad). The 60 pt
    /// minimum still holds.
    func testBelowTheSmallestFittingHeightNoTargetGoesUnder60Points() {
        let zoomedSE = ButtonPadLayout.make(width: 320, height: padHeight(screen: 568, safeTop: 20, safeBottom: 0))
        for rect in Array(zoomedSE.buttons.values) + [zoomedSE.fineSegment, zoomedSE.coarseSegment] {
            XCTAssertGreaterThanOrEqual(rect.width, 60 - 1e-9)
            XCTAssertGreaterThanOrEqual(rect.height, 60 - 1e-9)
        }
    }

    func testASmallPhoneShrinksEverythingByOneFactor() {
        let se = ButtonPadLayout.make(width: 375, height: padHeight(screen: 667, safeTop: 20, safeBottom: 0))
        let factor = se.buttons[.forward]!.width / 88
        XCTAssertLessThan(factor, 1)
        XCTAssertEqual(se.buttons[.up]!.height, 128 * factor, accuracy: 1e-9)
        XCTAssertEqual(se.buttons[.up]!.width, 96 * factor, accuracy: 1e-9)
        XCTAssertEqual(se.buttons[.open]!.height, 72 * factor, accuracy: 1e-9)
    }

    /// Shared edges do not count; the cells of the cross touch.
    private func overlap(_ a: PadRect, _ b: PadRect) -> Bool {
        let e = 1e-9
        return a.minX < b.maxX - e && b.minX < a.maxX - e && a.minY < b.maxY - e && b.minY < a.maxY - e
    }

    // MARK: The 20 pt drag-out

    func testAFingerSlipsOffOnlyWhenMoreThan20PointsOutside() {
        let rect = reference.buttons[.up]!
        XCTAssertFalse(reference.hasSlipped(off: .up, x: rect.midX, y: rect.midY))
        XCTAssertFalse(reference.hasSlipped(off: .up, x: rect.maxX, y: rect.midY), "on the edge")
        XCTAssertFalse(reference.hasSlipped(off: .up, x: rect.maxX + 20, y: rect.midY), "exactly 20 pt out")
        XCTAssertTrue(reference.hasSlipped(off: .up, x: rect.maxX + 20.5, y: rect.midY))
        XCTAssertTrue(reference.hasSlipped(off: .up, x: rect.midX, y: rect.maxY + 21))
        XCTAssertFalse(reference.hasSlipped(off: .up, x: rect.minX - 14, y: rect.minY - 14), "a corner, 19.8 pt away")
        XCTAssertTrue(reference.hasSlipped(off: .up, x: rect.minX - 15, y: rect.minY - 15), "a corner, 21.2 pt away")
    }

    func testDistanceOutsideARectangle() {
        let rect = PadRect(x: 10, y: 20, width: 30, height: 40)
        XCTAssertEqual(rect.distance(toX: 25, y: 40), 0)
        XCTAssertEqual(rect.distance(toX: 0, y: 40), 10)
        XCTAssertEqual(rect.distance(toX: 25, y: 70), 10)
        XCTAssertEqual(rect.distance(toX: 43, y: 64), 5)
    }
}
