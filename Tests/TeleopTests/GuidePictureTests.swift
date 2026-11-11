import simd
import TeleopCore
import XCTest
@testable import Teleop

final class GuidePictureTests: XCTestCase {
    private let profile = RobotProfile.so101Simulator
    private var centre: SIMD3<Float> { (profile.workspaceMin + profile.workspaceMax) / 2 }

    private func reading(
        _ pinch: SIMD3<Float>? = nil, commanded: SIMD3<Float>? = nil, jaws: Double? = 0.6,
        turn: Double? = 88, tilt: Double? = -4, target: SIMD3<Float>? = nil, goal: SIMD3<Float>? = nil,
        gripping: Bool = false
    ) -> ArmReading {
        ArmReading(
            pinchPoint: pinch ?? centre, commanded: commanded, jawOpening: jaws, wristTurnDeg: turn,
            wristTiltDeg: tilt, target: target, goal: goal, gripping: gripping
        )
    }

    private func picture(_ reading: ArmReading) -> GuidePicture { GuidePicture(reading: reading, profile: profile) }

    // MARK: The base form, with nothing but the arm

    func testBaseFormShowsTheArmAloneWithNoTaskMarks() {
        let p = picture(reading(commanded: centre + SIMD3(0.02, 0, 0)))
        XCTAssertNil(p.target)
        XCTAssertNil(p.goal)
        XCTAssertFalse(p.onTarget)
        XCTAssertFalse(p.holding)
        XCTAssertFalse(p.outside)
        let heightCm = Double(centre.z - profile.tableHeight) * 100
        XCTAssertEqual(p.lines.count, 3)
        guard case .height(let cm) = p.lines[0] else { return XCTFail("\(p.lines)") }
        XCTAssertEqual(cm, heightCm, accuracy: 0.001)
        XCTAssertEqual(p.lines[1], .jaws(percentOpen: 60))
        XCTAssertEqual(p.lines[2], .wrist(turnDeg: 88, tiltDeg: -4))
        // The box is centred in the view from above, so its centre is the view's centre.
        XCTAssertEqual(p.pinch.above.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(p.pinch.above.y, 0.5, accuracy: 1e-6)
        XCTAssertEqual(p.pinch.behind.x, p.pinch.above.x, accuracy: 1e-9, "one left-right axis for both views")
        XCTAssertFalse(p.pinch.pinned)
    }

    func testTheCommandedPointIsDrawnWhereTheArmIsAskedToGo() {
        // Base +x is the operator's left, so the commanded point is drawn left of the pinch point.
        let p = picture(reading(commanded: centre + SIMD3(0.02, 0, 0.01)))
        let commanded = try! XCTUnwrap(p.commanded)
        XCTAssertLessThan(commanded.above.x, p.pinch.above.x)
        XCTAssertEqual(commanded.behind.x, commanded.above.x, accuracy: 1e-9)
        XCTAssertLessThan(commanded.behind.y, p.pinch.behind.y, "higher up in the view from behind")
        XCTAssertNil(picture(reading()).commanded, "no commanded point when nothing moves")
    }

    func testUnreportedJawsAndWristLeaveTheirLinesOut() {
        let p = picture(reading(jaws: nil, turn: nil, tilt: nil))
        XCTAssertNil(p.jawOpening)
        XCTAssertEqual(p.lines.count, 1)
        XCTAssertEqual(picture(reading(turn: nil, tilt: 12.4)).lines.last, .wrist(turnDeg: nil, tiltDeg: 12))
        XCTAssertEqual(picture(reading(jaws: 1.4)).jawOpening, 1, "a reading past fully open is drawn fully open")
    }

    func testBothViewsShareOneScale() {
        let p = picture(reading())
        let spanAbove = (p.boxAbove.maxX - p.boxAbove.minX) / (p.boxAbove.maxY - p.boxAbove.minY) * p.aboveAspect
        let box = profile.workspaceMax - profile.workspaceMin
        XCTAssertEqual(spanAbove, Double(box.x / box.y), accuracy: 1e-6, "from above, the box keeps its shape")
        let floor = max(profile.workspaceMin.z, profile.tableHeight)
        let spanBehind = (p.boxBehind.maxX - p.boxBehind.minX) / (p.boxBehind.maxY - p.boxBehind.minY) * p.behindAspect
        XCTAssertEqual(spanBehind, Double(box.x / (profile.workspaceMax.z - floor)), accuracy: 1e-6,
                       "from behind, the box keeps its shape down to the table")
        XCTAssertEqual(p.boxBehind.maxY, p.tableY, accuracy: 1e-9, "the box stops at the table")
    }

    // MARK: The pinch point at each workspace edge

    func testThePinchPointOnEachFaceOfTheBoxIsDrawnOnThatEdge() {
        let lo = profile.workspaceMin, hi = profile.workspaceMax
        let c = centre
        // Base −x is the operator's right; base −y is forward, which is up in the view from above.
        let right = picture(reading(SIMD3(lo.x, c.y, c.z)))
        XCTAssertEqual(right.pinch.above.x, right.boxAbove.maxX, accuracy: 1e-9)
        let left = picture(reading(SIMD3(hi.x, c.y, c.z)))
        XCTAssertEqual(left.pinch.above.x, left.boxAbove.minX, accuracy: 1e-9)
        let far = picture(reading(SIMD3(c.x, lo.y, c.z)))
        XCTAssertEqual(far.pinch.above.y, far.boxAbove.minY, accuracy: 1e-9)
        let near = picture(reading(SIMD3(c.x, hi.y, c.z)))
        XCTAssertEqual(near.pinch.above.y, near.boxAbove.maxY, accuracy: 1e-9)
        let top = picture(reading(SIMD3(c.x, c.y, hi.z)))
        XCTAssertEqual(top.pinch.behind.y, top.boxBehind.minY, accuracy: 1e-9)
        let onTable = picture(reading(SIMD3(c.x, c.y, profile.tableHeight)))
        XCTAssertEqual(onTable.pinch.behind.y, onTable.tableY, accuracy: 1e-9)
        guard case .height(let cm) = onTable.lines[0] else { return XCTFail() }
        XCTAssertEqual(cm, 0, accuracy: 1e-6)
        for p in [right, left, far, near, top, onTable] {
            XCTAssertFalse(p.outside, "\(p.pinch)")
            XCTAssertFalse(p.pinch.pinned, "a mark on the box's edge is drawn whole")
            XCTAssertFalse(p.lines.contains(.outside))
            for spot in [p.pinch.above, p.pinch.behind] {
                XCTAssertTrue((0.02...0.98).contains(spot.x) && (0.02...0.98).contains(spot.y), "\(spot) leaves room to draw it")
            }
        }
    }

    func testAReadingOutsideTheBoxIsSaidAndPinnedToTheViewEdge() {
        let lo = profile.workspaceMin
        let c = centre
        let p = picture(reading(SIMD3(lo.x - 0.06, c.y, c.z)))
        XCTAssertTrue(p.outside)
        XCTAssertEqual(p.lines.last, .outside)
        XCTAssertTrue(p.pinch.pinned)
        XCTAssertEqual(p.pinch.above.x, 1, "drawn on the right edge")
        XCTAssertEqual(p.pinch.behind.x, 1)
        // Just outside the face but inside the room around the box: said, but drawn where it is.
        let justOut = picture(reading(SIMD3(lo.x - 0.005, c.y, c.z)))
        XCTAssertTrue(justOut.outside)
        XCTAssertFalse(justOut.pinch.pinned)
        XCTAssertGreaterThan(justOut.pinch.above.x, justOut.boxAbove.maxX)
        // Within a millimetre of the face still counts as inside.
        XCTAssertFalse(picture(reading(SIMD3(lo.x - 0.0005, c.y, c.z))).outside)
    }

    // MARK: Task objects

    func testATargetAloneAddsItsMarkAndTheGap() {
        let target = centre + SIMD3(-0.03, 0.04, -0.02)
        let p = picture(reading(target: target))
        let mark = try! XCTUnwrap(p.target)
        XCTAssertNil(p.goal)
        XCTAssertEqual(mark.behind.x, mark.above.x, accuracy: 1e-9)
        XCTAssertGreaterThan(mark.behind.y, p.pinch.behind.y, "lower than the pinch point")
        guard case .target(let across, let height) = p.lines[3] else { return XCTFail("\(p.lines)") }
        XCTAssertEqual(across, 5, accuracy: 1e-4)
        guard case .above(let cm) = height else { return XCTFail("\(height)") }
        XCTAssertEqual(cm, 2, accuracy: 1e-4)
        XCTAssertFalse(p.onTarget)
        XCTAssertFalse(p.lines.contains(.onTarget))
        let box = profile.workspaceMax - profile.workspaceMin
        let viewWidth = Double(box.x) + 2 * GuidePicture.marginShare * Double(max(box.x, box.y))
        XCTAssertEqual(p.targetEdge, Double(profile.targetSize) / viewWidth, accuracy: 1e-6, "true to size, from the profile")
    }

    func testOnTargetOnlyInsideTheProfilesTolerance() {
        let tolerance = profile.graspTolerance
        let inside = centre + SIMD3(tolerance.x * 0.6, 0, tolerance.y * 0.9)
        let p = picture(reading(target: inside))
        XCTAssertTrue(p.onTarget)
        XCTAssertEqual(p.lines.last, .onTarget)
        guard case .target(_, let height) = p.lines[3] else { return XCTFail() }
        XCTAssertEqual(height, .level)
        XCTAssertFalse(picture(reading(target: centre + SIMD3(tolerance.x * 1.2, 0, 0))).onTarget, "too far across")
        let tooLow = picture(reading(target: centre + SIMD3(0, 0, tolerance.y * 1.3)))
        XCTAssertFalse(tooLow.onTarget, "too far in height")
        guard case .target(_, .below(let cm)) = tooLow.lines[3] else { return XCTFail("\(tooLow.lines)") }
        XCTAssertEqual(cm, Double(tolerance.y * 1.3) * 100, accuracy: 1e-3)
    }

    func testTargetAndGoalShowBothMarksAndTheGapToTheTarget() {
        let target = centre + SIMD3(0, 0.03, -0.02), goal = centre + SIMD3(0.06, 0.03, -0.02)
        let p = picture(reading(target: target, goal: goal))
        XCTAssertNotNil(p.target)
        let goalMark = try! XCTUnwrap(p.goal)
        XCTAssertLessThan(goalMark.above.x, try! XCTUnwrap(p.target).above.x, "base +x is the operator's left")
        XCTAssertTrue(p.lines.contains { if case .target = $0 { return true } else { return false } })
        XCTAssertFalse(p.lines.contains { if case .goal = $0 { return true } else { return false } })
        XCTAssertFalse(p.holding)
        XCTAssertEqual(p.goalEdge / p.targetEdge, Double(profile.goalSize / profile.targetSize), accuracy: 1e-6)
    }

    /// The sizes come from the robot profile alone, so another task draws its own object and goal.
    func testTheTargetAndGoalSizesComeFromTheProfile() {
        var other = profile
        other.targetSize *= 2
        other.goalSize *= 3
        let r = reading(target: centre + SIMD3(0, 0.03, -0.02), goal: centre + SIMD3(0.06, 0.03, -0.02))
        let base = GuidePicture(reading: r, profile: profile), bigger = GuidePicture(reading: r, profile: other)
        XCTAssertEqual(bigger.targetEdge, base.targetEdge * 2, accuracy: 1e-6)
        XCTAssertEqual(bigger.goalEdge, base.goalEdge * 3, accuracy: 1e-6)
    }

    func testHoldingSteersToTheGoal() {
        let target = centre, goal = centre + SIMD3(0.04, -0.03, -0.01)
        let p = picture(reading(jaws: 0.1, target: target, goal: goal, gripping: true))
        XCTAssertTrue(p.holding)
        XCTAssertFalse(p.onTarget, "on target is for an object not yet held")
        XCTAssertTrue(p.lines.contains(.holding))
        XCTAssertFalse(p.lines.contains { if case .target = $0 { return true } else { return false } })
        guard case .goal(let across, let height) = p.lines.last else { return XCTFail("\(p.lines)") }
        XCTAssertEqual(across, 5, accuracy: 1e-4)
        guard case .above(let cm) = height else { return XCTFail("\(height)") }
        XCTAssertEqual(cm, 1, accuracy: 1e-4)
    }

    func testGrippingWithNoTaskObjectsSaysNothingAboutHolding() {
        // A robot that reports no objects: the guide cannot know what the jaws have, only how far they are open.
        let p = picture(reading(jaws: 0.05, gripping: true))
        XCTAssertFalse(p.holding)
        XCTAssertEqual(p.lines.count, 3)
    }

    // MARK: Words

    func testReadOutsInBothLanguages() {
        let language = L10n.language
        defer { L10n.language = language }
        L10n.language = .en
        XCTAssertEqual(GuideWords.text(.height(cm: 6.04)), "Height 6.0 cm")
        XCTAssertEqual(GuideWords.text(.jaws(percentOpen: 60)), "Jaws 60% open")
        XCTAssertEqual(GuideWords.text(.wrist(turnDeg: 88, tiltDeg: -4)), "Wrist turn 88° · tilt -4°")
        XCTAssertEqual(GuideWords.text(.wrist(turnDeg: nil, tiltDeg: 12)), "Wrist tilt 12°")
        XCTAssertEqual(GuideWords.text(.target(acrossCm: 5, height: .above(cm: 2))), "Target 5.0 cm across · 2.0 cm above")
        XCTAssertEqual(GuideWords.text(.target(acrossCm: 0.4, height: .level)), "Target 0.4 cm across · level")
        XCTAssertEqual(GuideWords.text(.goal(acrossCm: 3, height: .below(cm: 1.5))), "Goal 3.0 cm across · 1.5 cm below")
        XCTAssertEqual(GuideWords.text(.onTarget), "On target")
        XCTAssertEqual(GuideWords.text(.holding), "Holding")
        XCTAssertEqual(GuideWords.text(.outside), "Outside the work area")
        L10n.language = .zhHant
        XCTAssertEqual(GuideWords.text(.height(cm: 6.04)), "離桌面 6.0 公分")
        XCTAssertEqual(GuideWords.text(.jaws(percentOpen: 60)), "夾爪張開 60%")
        XCTAssertEqual(GuideWords.text(.wrist(turnDeg: 88, tiltDeg: -4)), "手腕轉 88° · 傾 -4°")
        XCTAssertEqual(GuideWords.text(.target(acrossCm: 5, height: .above(cm: 2))), "目標物：水平差 5.0 公分 · 高 2.0 公分")
        XCTAssertEqual(GuideWords.text(.goal(acrossCm: 3, height: .level)), "目標區：水平差 3.0 公分 · 等高")
        XCTAssertEqual(GuideWords.text(.onTarget), "對準目標物")
        XCTAssertEqual(GuideWords.text(.holding), "夾持中")
        XCTAssertEqual(GuideWords.text(.outside), "超出工作範圍")
    }
}
