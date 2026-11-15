import XCTest
import simd
@testable import TeleopCore

/// The view from above as the input rules judge a tap on it: a tap asks for the place drawn under the finger, at the
/// travel height above the table, and only a place inside the work box as drawn can be gone to.
final class GoPanelTests: XCTestCase {
    /// The SO-101 simulator's work box, robot base frame, pinch point, and its table height.
    private let boxMin = SIMD3(-0.052383, -0.257418, -0.008015)
    private let boxMax = SIMD3(0.107617, -0.097418, 0.151985)
    private let table = 0.04
    private let travel = 0.05
    /// About where the reference phone draws the SO-101 guide's view from above.
    private let rect = SurfaceLayout.Rect(x: 118, y: 262, width: 166, height: 166)

    /// As the app will build it from the guide: the box moved by `shift`, drawn with the projection of that box.
    private func panel(shift: SIMD3<Double> = .zero) -> GoPanel {
        let low = boxMin + shift, high = boxMax + shift
        let a = GuideProjection.operatorPoint(low), b = GuideProjection.operatorPoint(high)
        let projection = GuideProjection(boxLow: simd_min(a, b), boxHigh: simd_max(a, b), table: table)
        return GoPanel(
            rect: rect, projection: projection, boxLow: simd_min(low, high), boxHigh: simd_max(low, high),
            tableHeight: table)
    }

    func testATapMapsToTheDrawnPointAtTravelHeight() {
        let p = panel()
        // The box is centred in the view, so the panel's centre asks for the box's centre.
        let centre = p.target(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2, travelHeight: travel)
        let boxCentre = (boxMin + boxMax) / 2
        XCTAssertEqual(centre.x, boxCentre.x, accuracy: 1e-9)
        XCTAssertEqual(centre.y, boxCentre.y, accuracy: 1e-9)
        XCTAssertEqual(centre.z, table + travel, "exactly the travel height above the table")
        XCTAssertTrue(p.inBox(centre))
        // The panel's top left corner is the view's far left corner: base +x is the operator's left, base −y forward.
        let corner = p.target(x: rect.x, y: rect.y, travelHeight: travel)
        XCTAssertEqual(corner.x, 0.131617, accuracy: 1e-9)
        XCTAssertEqual(corner.y, -0.281418, accuracy: 1e-9)
        // A quarter across and a quarter down: left of centre and farther forward, by a quarter of the 20.8 cm view.
        let quarter = p.target(x: rect.x + rect.width / 4, y: rect.y + rect.height / 4, travelHeight: travel)
        XCTAssertEqual(quarter.x, boxCentre.x + 0.052, accuracy: 1e-9)
        XCTAssertEqual(quarter.y, boxCentre.y - 0.052, accuracy: 1e-9)
        XCTAssertEqual(quarter.z, table + travel)
        // The place the tap asks for is drawn under the finger.
        let drawn = p.point(over: quarter)
        XCTAssertEqual(drawn.x, rect.x + rect.width / 4, accuracy: 1e-9)
        XCTAssertEqual(drawn.y, rect.y + rect.height / 4, accuracy: 1e-9)
        XCTAssertTrue(p.contains(x: rect.x, y: rect.y))
        XCTAssertFalse(p.contains(x: rect.x - 0.5, y: rect.y + 10))
        XCTAssertFalse(p.contains(x: rect.maxX, y: rect.y + 10))
    }

    func testTheBoxHasNoSlack() {
        let p = panel()
        let centre = (boxMin + boxMax) / 2
        for axis in 0..<3 {
            for (face, outward) in [(boxMin[axis], -1.0), (boxMax[axis], 1.0)] {
                var point = centre
                point[axis] = face
                XCTAssertTrue(p.inBox(point), "on the face, axis \(axis)")
                point[axis] = face - outward * 0.001
                XCTAssertTrue(p.inBox(point), "1 mm inside, axis \(axis)")
                point[axis] = face + outward * 0.001
                XCTAssertFalse(p.inBox(point), "1 mm outside a face is outside, axis \(axis)")
            }
        }
        XCTAssertFalse(p.inBox(SIMD3(.nan, centre.y, centre.z)), "a place that is not a number is never inside")
    }

    func testAPointInTheMarginIsOutside() {
        let p = panel()
        // The box spans shares 0.115 to 0.885 of the view; the margin lies around it, inside the panel.
        for (sx, sy) in [(0.05, 0.5), (0.95, 0.5), (0.5, 0.05), (0.5, 0.95), (0.02, 0.98)] {
            let x = rect.x + sx * rect.width, y = rect.y + sy * rect.height
            XCTAssertTrue(p.contains(x: x, y: y), "\(sx), \(sy)")
            XCTAssertFalse(p.inBox(p.target(x: x, y: y, travelHeight: travel)), "\(sx), \(sy)")
        }
        for (sx, sy) in [(0.12, 0.5), (0.88, 0.5), (0.5, 0.12), (0.5, 0.88)] {
            let x = rect.x + sx * rect.width, y = rect.y + sy * rect.height
            XCTAssertTrue(p.inBox(p.target(x: x, y: y, travelHeight: travel)), "just inside the box, \(sx), \(sy)")
        }
        // A travel height past the box's top is outside wherever the tap lands.
        let centre = (x: rect.x + rect.width / 2, y: rect.y + rect.height / 2)
        XCTAssertFalse(p.inBox(p.target(x: centre.x, y: centre.y, travelHeight: boxMax.z - table + 0.001)))
        XCTAssertTrue(p.inBox(p.target(x: centre.x, y: centre.y, travelHeight: boxMax.z - table - 0.001)))
    }

    /// With a reported tool point the guide draws the box moved by the measured offset; the panel judges that box.
    func testTheBoxIsTheDrawnBoxWithItsShift() {
        let shift = SIMD3(0.02, -0.01, 0.015)
        let p = panel(shift: shift)
        let centre = p.target(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2, travelHeight: travel)
        XCTAssertEqual(centre.x, (boxMin.x + boxMax.x) / 2 + shift.x, accuracy: 1e-9, "the moved box is centred")
        XCTAssertEqual(centre.y, (boxMin.y + boxMax.y) / 2 + shift.y, accuracy: 1e-9)
        XCTAssertEqual(centre.z, table + travel, "the table does not move with the box")
        // Inside the profile's box, but nearer the base than the moved box's near face.
        let past = SIMD3((boxMin.x + boxMax.x) / 2, boxMax.y - 0.005, table + travel)
        XCTAssertTrue(panel().inBox(past))
        XCTAssertFalse(panel(shift: SIMD3(0, -0.02, 0)).inBox(past))
        // The moved box's corners are drawn where the unmoved box's corners are drawn in the unmoved panel: each
        // panel is drawn around its own box.
        for corner in [boxMin, boxMax, SIMD3(boxMin.x, boxMax.y, 0), SIMD3(boxMax.x, boxMin.y, 0)] {
            let moved = p.point(over: corner + shift), plain = panel().point(over: corner)
            XCTAssertEqual(moved.x, plain.x, accuracy: 1e-9)
            XCTAssertEqual(moved.y, plain.y, accuracy: 1e-9)
        }
    }

    func testPointOverIsTheInverse() {
        let p = panel(shift: SIMD3(-0.01, 0.02, 0))
        var random = SplitMix64(seed: 0x60_9A4E1)
        for i in 0..<1000 {
            let x = random.uniform(rect.x - 20, rect.maxX + 20), y = random.uniform(rect.y - 20, rect.maxY + 20)
            let drawn = p.point(over: p.target(x: x, y: y, travelHeight: travel))
            XCTAssertEqual(drawn.x, x, accuracy: 1e-9, "\(i)")
            XCTAssertEqual(drawn.y, y, accuracy: 1e-9, "\(i)")
            let base = SIMD3(random.uniform(-0.1, 0.2), random.uniform(-0.35, 0), random.uniform(0, 0.2))
            let tap = p.point(over: base)
            let back = p.target(x: tap.x, y: tap.y, travelHeight: travel)
            XCTAssertEqual(back.x, base.x, accuracy: 1e-9, "\(i)")
            XCTAssertEqual(back.y, base.y, accuracy: 1e-9, "\(i)")
            XCTAssertEqual(back.z, table + travel, "\(i)")
        }
    }
}
