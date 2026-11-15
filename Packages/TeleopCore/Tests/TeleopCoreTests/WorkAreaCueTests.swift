import XCTest
import simd
@testable import TeleopCore

/// The work-area rule: every time the commanded place leaves the box, on which side, once per crossing, never twice
/// within 1.5 s, and the line and the cue read one value.
final class WorkAreaCueTests: XCTestCase {
    /// The SO-101 simulator's box, robot base frame, pinch point, and its tool offset: the rule's box is the first
    /// minus the second.
    private let pinchMin = SIMD3(-0.052383, -0.257418, -0.008015)
    private let pinchMax = SIMD3(0.107617, -0.097418, 0.151985)
    private let toolOffset = SIMD3(0.007, -0.036, -0.088)

    private var low: SIMD3<Double> { pinchMin - toolOffset }
    private var high: SIMD3<Double> { pinchMax - toolOffset }
    private var centre: SIMD3<Double> { (low + high) / 2 }

    private var cue: WorkAreaCue!
    private var clock = 0

    override func setUp() {
        cue = WorkAreaCue(low: low, high: high)
        clock = 0
    }

    /// A point `metres` past the face on `side` (negative: inside it), at the box's centre on the other axes.
    private func past(_ side: OperatorDirection, by metres: Double, from start: SIMD3<Double>? = nil) -> SIMD3<Double> {
        var point = start ?? centre
        let (axis, sign) = side.baseAxis
        let i = axis == .x ? 0 : (axis == .y ? 1 : 2)
        point[i] = (sign > 0 ? high[i] : low[i]) + sign * metres
        return point
    }

    /// One tick, `ms` after the last.
    @discardableResult
    private func tick(_ point: SIMD3<Double>, after ms: Int = 20) -> OperatorDirection? {
        clock += ms
        return cue.commanded(point, at: clock)
    }

    func testCrossingEachFaceNamesThatSide() {
        // The axis table: base −y is forward, +y back, +x left, −x right, +z up, −z down.
        let expected: [OperatorDirection: (axis: Int, sign: Double)] = [
            .forward: (1, -1), .back: (1, 1), .left: (0, 1), .right: (0, -1), .up: (2, 1), .down: (2, -1),
        ]
        for side in OperatorDirection.allCases {
            setUp()
            XCTAssertNil(tick(centre))
            XCTAssertNil(cue.outside)
            var point = centre
            let (axis, sign) = try! XCTUnwrap(expected[side])
            point[axis] = (sign > 0 ? high[axis] : low[axis]) + sign * 0.003
            XCTAssertEqual(tick(point), side, "\(side)")
            XCTAssertEqual(cue.outside, side, "\(side)")
        }
        // The corners may be given in either order.
        var swapped = WorkAreaCue(low: high, high: low)
        XCTAssertEqual(swapped.low, low)
        XCTAssertEqual(swapped.commanded(past(.forward, by: 0.003), at: 0), .forward)
    }

    func testTheSlackCountsAsInside() {
        XCTAssertNil(tick(past(.left, by: 0.0019)), "within the guide's own millimetre and rounding")
        XCTAssertNil(cue.outside)
        XCTAssertEqual(tick(past(.left, by: 0.0021)), .left)
        XCTAssertEqual(cue.outside, .left)
    }

    func testTheLargestExcessWinsAtACorner() {
        XCTAssertEqual(tick(past(.left, by: 0.004, from: past(.forward, by: 0.006))), .forward)
        setUp()
        XCTAssertEqual(tick(past(.left, by: 0.006, from: past(.forward, by: 0.004))), .left)
        setUp()
        XCTAssertEqual(tick(past(.up, by: 0.03, from: past(.right, by: 0.01))), .up)
        XCTAssertEqual(cue.outside, .up)
    }

    func testOneEventPerCrossing() {
        XCTAssertNil(tick(centre))
        XCTAssertEqual(tick(past(.forward, by: 0.003)), .forward)
        // Ten seconds farther and farther out: the line stays, the cue does not repeat.
        for step in 1...500 {
            XCTAssertNil(tick(past(.forward, by: 0.003 + Double(step) * 0.0002)), "\(step)")
            XCTAssertEqual(cue.outside, .forward)
        }
        XCTAssertNil(tick(centre))
        XCTAssertNil(cue.outside, "the line goes as the point comes back")
    }

    func testASideChangeWhileOutsideIsToldAgainOnceTheGapAllows() {
        XCTAssertEqual(tick(past(.forward, by: 0.006)), .forward)
        // Along the far face into the corner, farther past the left face than the forward one: told, but not
        // within 1.5 s of the last cue; the line says it at once.
        let corner = past(.left, by: 0.009, from: past(.forward, by: 0.006))
        XCTAssertNil(tick(corner, after: 500))
        XCTAssertEqual(cue.outside, .left)
        XCTAssertNil(tick(corner, after: 980))
        XCTAssertEqual(tick(corner, after: 20), .left, "played on the first tick the gap allows")
        XCTAssertNil(tick(corner))
        // And back to farther forward than left.
        XCTAssertEqual(tick(past(.left, by: 0.003, from: past(.forward, by: 0.006)), after: 1500), .forward)
    }

    func testHoveringAtTheEdgeGivesOneEventPerGapAtMost() {
        // In and out across the face every 100 ms for 6 s, far enough in each time to arm it again.
        var played: [Int] = []
        for step in 0..<60 {
            let out = step % 2 == 0
            let side = tick(out ? past(.back, by: 0.003) : past(.back, by: -0.006), after: 100)
            XCTAssertEqual(cue.outside, out ? .back : nil, "the line follows the point at every tick, \(step)")
            if let side {
                XCTAssertEqual(side, .back)
                played.append(clock)
            }
        }
        XCTAssertEqual(played.first, 100)
        XCTAssertGreaterThanOrEqual(played.count, 3, "still told while it keeps crossing")
        for (a, b) in zip(played, played.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, WorkAreaCue.minimumGapMs)
        }
    }

    func testReArmedAfterComingBackFiveMillimetres() {
        XCTAssertEqual(tick(past(.down, by: 0.003)), .down)
        // Back 4 mm inside the face and out again, well after the gap: a point resting on the face is told once.
        XCTAssertNil(tick(past(.down, by: -0.004), after: 2000))
        XCTAssertNil(cue.outside)
        XCTAssertNil(tick(past(.down, by: 0.003), after: 2000))
        XCTAssertEqual(cue.outside, .down)
        // Back 5 mm inside: armed again.
        XCTAssertNil(tick(past(.down, by: -0.005), after: 2000))
        XCTAssertEqual(tick(past(.down, by: 0.003)), .down)
    }

    /// Resting near one face does not keep another side from being told again: each side arms on its own face.
    func testComingBackFromOneFaceArmsItWhileResting4mmFromAnother() {
        let nearRight = past(.right, by: -0.003)
        XCTAssertEqual(tick(past(.forward, by: 0.003, from: nearRight)), .forward)
        XCTAssertNil(tick(past(.forward, by: -0.01, from: nearRight), after: 2000))
        XCTAssertEqual(tick(past(.forward, by: 0.003, from: nearRight), after: 2000), .forward)
    }

    func testReArmedAtANewStart() {
        XCTAssertEqual(tick(past(.up, by: 0.004)), .up)
        XCTAssertNil(tick(past(.up, by: 0.004), after: 2000), "still out: told once")
        cue.holdStarted()
        XCTAssertEqual(tick(past(.up, by: 0.004)), .up, "a new hold that starts out of the box is told")
        // The gap still holds across a new start, and a cue it holds back plays once it has passed.
        cue.holdStarted()
        XCTAssertNil(tick(past(.up, by: 0.004), after: 100))
        XCTAssertEqual(tick(past(.up, by: 0.004), after: 1400), .up)
    }

    func testNothingWithoutABox() {
        // Not known on one axis, unbounded everywhere, unbounded on one side only.
        let unbounded = SIMD3(Double.infinity, .infinity, .infinity)
        let boxes = [
            (low, SIMD3(.nan, high.y, high.z)), (-unbounded, unbounded), (low, SIMD3(high.x, high.y, .infinity)),
        ]
        for box in boxes {
            var rule = WorkAreaCue(low: box.0, high: box.1)
            for (i, point) in [centre, centre + SIMD3(0, -0.5, 0), centre + SIMD3(1, 1, 1)].enumerated() {
                XCTAssertNil(rule.commanded(point, at: i * 2000), "\(box)")
                XCTAssertNil(rule.outside, "\(box)")
            }
        }
        // A commanded point that is not a number is never outside.
        XCTAssertNil(tick(SIMD3(.nan, centre.y, centre.z)))
        XCTAssertNil(cue.outside)
    }

    /// The guide draws the commanded ring at the commanded gripper-link point plus the measured offset, and the box at
    /// the profile's box moved by that offset minus the profile's tool offset. So the box in gripper-link space is the
    /// drawn box minus the measured offset, and the rule says what the picture shows, whatever the offset.
    func testTheGripperLinkBoxIsTheDrawnBoxMinusTheMeasuredOffset() {
        let commanded = [
            centre, past(.forward, by: 0.1), past(.left, by: 0.003), past(.up, by: 0.001), past(.back, by: -0.004),
            past(.right, by: 0.004, from: past(.down, by: 0.006)),
        ]
        for measured in [toolOffset, SIMD3(0.02, -0.05, -0.07), SIMD3(-0.01, -0.02, -0.11)] {
            let shift = measured - toolOffset
            let drawnLow = pinchMin + shift, drawnHigh = pinchMax + shift
            let linkBox = WorkAreaCue(low: low, high: high)
            XCTAssertEqual(simd_distance(linkBox.low, drawnLow - measured), 0, accuracy: 1e-12)
            XCTAssertEqual(simd_distance(linkBox.high, drawnHigh - measured), 0, accuracy: 1e-12)
            for point in commanded {
                var rule = WorkAreaCue(low: low, high: high)
                var picture = WorkAreaCue(low: drawnLow, high: drawnHigh)
                XCTAssertEqual(rule.commanded(point, at: 0), picture.commanded(point + measured, at: 0), "\(point)")
                XCTAssertEqual(rule.outside, picture.outside, "\(point)")
            }
        }
    }
}
