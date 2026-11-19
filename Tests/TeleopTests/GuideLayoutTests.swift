import TeleopCore
import XCTest
@testable import Teleop

final class GuideLayoutTests: XCTestCase {
    func testTheFixedGuideFitsAboveTheGapAtBothHeights() {
        let profile = RobotProfile.so101Simulator
        let reading = ArmReading(
            pinchPoint: SIMD3(0, -0.17, 0.1), commanded: nil, jawOpening: nil, wristTurnDeg: nil, wristTiltDeg: nil,
            target: nil, goal: nil, gripping: false)
        let picture = GuidePicture(reading: reading, profile: profile, views: profile.assist.views)
        for (width, height, top, bottom, expected) in [
            (402.0, 874.0, 62.0, 34.0, 273.0),
            (375.0, 667.0, 20.0, 0.0, 235.0),
        ] {
            let surface = SurfaceLayout(width: width, height: height, safeTop: top, safeBottom: bottom)
            let layout = GuideLayout(
                surface: surface, aboveAspect: picture.aboveAspect, behindAspect: picture.behindAspect, practice: false)
            XCTAssertEqual(layout.above.width, expected, accuracy: 1)
            XCTAssertEqual(layout.behind.width, layout.above.width)
            XCTAssertEqual(layout.behind.y - layout.above.maxY, 6)
            XCTAssertLessThan(layout.readout.maxY, layout.hint.y)
            XCTAssertLessThan(layout.hint.maxY, surface.controlSurface.height)
        }
    }

    func testPrecisionFooterLeavesGuideReadoutAndHintAboveTheEntry() {
        let profile = RobotProfile.so101Simulator
        let reading = ArmReading(
            pinchPoint: SIMD3(0, -0.17, 0.1), commanded: nil, jawOpening: nil, wristTurnDeg: nil, wristTiltDeg: nil,
            target: nil, goal: nil, gripping: false)
        let picture = GuidePicture(reading: reading, profile: profile, views: profile.assist.views)
        for (width, height, top, bottom) in [(402.0, 874.0, 62.0, 34.0), (375.0, 667.0, 20.0, 0.0)] {
            for practice in [false, true] {
                let surface = SurfaceLayout(width: width, height: height, safeTop: top, safeBottom: bottom)
                let original = GuideLayout(
                    surface: surface, aboveAspect: picture.aboveAspect, behindAspect: picture.behindAspect,
                    practice: practice)
                let reserved = GuideLayout(
                    surface: surface, aboveAspect: picture.aboveAspect, behindAspect: picture.behindAspect,
                    practice: practice, footerHeight: 56)
                let entryTop = surface.controlSurface.height - 52
                XCTAssertEqual(reserved.word, original.word)
                XCTAssertEqual(reserved.detail, original.detail)
                XCTAssertEqual(reserved.above.y, original.above.y)
                XCTAssertGreaterThan(reserved.above.width, 0)
                if height == 874, !practice {
                    XCTAssertGreaterThan(
                        reserved.above.width, 240, "the footer must preserve the regular guide's tap area")
                }
                XCTAssertEqual(reserved.behind.width, reserved.above.width)
                XCTAssertGreaterThanOrEqual(reserved.readout.height, 3 * max(13, 15 * height / 874) * 1.45)
                XCTAssertLessThan(reserved.readout.maxY, reserved.hint.y)
                XCTAssertLessThan(reserved.hint.maxY, entryTop)
                XCTAssertEqual(original.hint.y - reserved.hint.y, 56, accuracy: 1e-9)
            }
        }
    }

    func testPrecisionFooterRetainsTheLargeGuideAndSeparatesTheHint() {
        let profile = RobotProfile.so101Simulator
        let reading = ArmReading(
            pinchPoint: SIMD3(0, -0.17, 0.1), commanded: nil, jawOpening: nil, wristTurnDeg: nil, wristTiltDeg: nil,
            target: nil, goal: nil, gripping: false)
        let picture = GuidePicture(reading: reading, profile: profile, views: profile.assist.views)
        for (width, height, top, bottom) in [(402.0, 874.0, 62.0, 34.0), (375.0, 667.0, 20.0, 0.0)] {
            let surface = SurfaceLayout(width: width, height: height, safeTop: top, safeBottom: bottom)
            let reserved = GuideLayout(
                surface: surface, aboveAspect: picture.aboveAspect, behindAspect: picture.behindAspect,
                practice: false, footerHeight: 48)
            XCTAssertLessThan(reserved.hint.maxY, surface.controlSurface.height - 52)
            if height == 874 { XCTAssertGreaterThan(reserved.above.width, 240) }
        }
    }

    func testMovingTheGripperOffsetDoesNotMoveTheProjection() {
        let profile = RobotProfile.so101Simulator
        var reading = ArmReading(
            pinchPoint: SIMD3(0, -0.17, profile.tableHeight + 0.11), commanded: nil, jawOpening: nil,
            wristTurnDeg: nil, wristTiltDeg: nil, target: nil, goal: nil, gripping: false)
        let first = GuidePicture(reading: reading, profile: profile, views: profile.assist.views)
        reading.boxShift = SIMD3(0.02, 0.01, 0)
        let second = GuidePicture(reading: reading, profile: profile, views: profile.assist.views)
        XCTAssertEqual(first.projection, second.projection)
        XCTAssertNotEqual(first.workBoxLow, second.workBoxLow)
        XCTAssertEqual(first.projection.height.upperBound - Double(profile.tableHeight), 0.09, accuracy: 1e-9)
        XCTAssertTrue(first.pinchAboveRearView)
        XCTAssertEqual(first.pinch.behind.y, 0)
    }
}
