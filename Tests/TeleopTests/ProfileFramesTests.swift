import XCTest
import simd
import TeleopCore

@testable import Teleop

/// The app's rules that read the profile's frames, run with the SO-101's profile and with the same arm written in
/// another base (`TestFrames`): what they do for it is what they do for the SO-101, carried through the frames. No
/// expected value of the other base is typed here.
final class ProfileFramesTests: XCTestCase {
    private let so = TestProfiles.so101
    private let others = TestFrames.all.dropFirst()

    /// The SO-101 profile with its base-frame numbers (the tool offset, the box) written in `frames`' base, and
    /// `frames` in place of its own. The table's height is along up, so it does not change.
    private func profile(on frames: Frames) -> RobotProfile {
        var p = so
        let from = so.frames
        p.toolOffset = TestFrames.carry(so.toolOffset, from: from, to: frames)
        p.offsetMeasuredAt = TestFrames.carry(so.offsetMeasuredAt, from: from, to: frames)
        let a = TestFrames.carry(so.workspaceMin, from: from, to: frames)
        let b = TestFrames.carry(so.workspaceMax, from: from, to: frames)
        p.workspaceMin = simd_min(a, b)
        p.workspaceMax = simd_max(a, b)
        p.frames = frames
        return p
    }

    // MARK: The guide's picture

    private func reading(_ profile: RobotProfile, carriedTo frames: Frames, lowestPinchZ: Float? = 0.045) -> ArmReading
    {
        let from = profile.frames
        func carry(_ p: SIMD3<Float>) -> SIMD3<Float> { TestFrames.carry(p, from: from, to: frames) }
        let centre = (profile.workspaceMin + profile.workspaceMax) / 2
        let pinch = centre + SIMD3(0.011, -0.007, -0.02)
        var reading = ArmReading(
            pinchPoint: carry(pinch), commanded: carry(pinch + SIMD3(0, -0.03, 0)), jawOpening: 0.6, wristTurnDeg: 88,
            wristTiltDeg: -4, target: carry(centre + SIMD3(0.03, 0.02, -0.04)),
            goal: carry(centre + SIMD3(-0.04, 0.01, -0.04)), gripping: false)
        reading.boxShift = carry(SIMD3(0.001, -0.002, 0.003))
        reading.goTarget = carry(centre + SIMD3(0.01, 0, 0))
        reading.commandOutside = .left
        reading.lowestGripperZ = 0.133
        reading.lowestPinchZ = lowestPinchZ
        return reading
    }

    private static let allAids = GuideAids(
        workAreaWords: true, lowestCue: true, shadow: true, directionLabels: true, widerOnTarget: true)

    private func assertSame(
        _ a: GuidePicture, _ b: GuidePicture, _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(a.projection.across, b.projection.across, message, file: file, line: line)
        XCTAssertEqual(a.projection.depth, b.projection.depth, message, file: file, line: line)
        XCTAssertEqual(a.projection.height, b.projection.height, message, file: file, line: line)
        XCTAssertEqual(a.boxAbove, b.boxAbove, message, file: file, line: line)
        XCTAssertEqual(a.boxBehind, b.boxBehind, message, file: file, line: line)
        XCTAssertEqual(a.tableY, b.tableY, message, file: file, line: line)
        XCTAssertEqual(a.pinch, b.pinch, message, file: file, line: line)
        XCTAssertEqual(a.commanded, b.commanded, message, file: file, line: line)
        XCTAssertEqual(a.goTarget, b.goTarget, message, file: file, line: line)
        XCTAssertEqual(a.target, b.target, message, file: file, line: line)
        XCTAssertEqual(a.goal, b.goal, message, file: file, line: line)
        XCTAssertEqual(a.targetGap, b.targetGap, message, file: file, line: line)
        XCTAssertEqual(a.lines, b.lines, message, file: file, line: line)
        XCTAssertEqual(a.lowestY, b.lowestY, message, file: file, line: line)
        XCTAssertEqual(a.lift, b.lift, message, file: file, line: line)
        XCTAssertEqual(a.outside, b.outside, message, file: file, line: line)
        XCTAssertEqual(a.onTarget, b.onTarget, message, file: file, line: line)
        XCTAssertEqual(a.holding, b.holding, message, file: file, line: line)
        XCTAssertEqual(a.approximate, b.approximate, message, file: file, line: line)
        XCTAssertEqual(a.pinchAboveRearView, b.pinchAboveRearView, message, file: file, line: line)
    }

    /// The guide draws the same picture, with every number and every line of words, whichever way the base is turned:
    /// the table, the work box, the heights, the lowest line and the sides.
    func testTheGuideDrawsTheSamePictureOnEveryBase() {
        let views = ViewAim(behindTopAboveTableM: 0.09)
        for (name, frames) in others {
            let other = profile(on: frames)
            // With and without the pinch point's own lowest height: without it the gripper link's is moved by the
            // measured offset, which is a height too.
            for lowestPinchZ in [Float?.none, 0.045] {
                for (aids, aim) in [(nil, nil), (Self.allAids, nil), (Self.allAids, views)] as [(GuideAids?, ViewAim?)]
                {
                    let first = GuidePicture(
                        reading: reading(so, carriedTo: so.frames, lowestPinchZ: lowestPinchZ), profile: so, aids: aids,
                        views: aim)
                    let second = GuidePicture(
                        reading: reading(so, carriedTo: frames, lowestPinchZ: lowestPinchZ), profile: other,
                        aids: aids, views: aim)
                    assertSame(first, second, "\(name) aids \(aids != nil) views \(aim != nil) \(lowestPinchZ as Any)")
                }
            }
        }
    }

    /// A mark of the picture is where the operator sees the place: a tap on it asks for the place carried too.
    func testTheGuideReadsBackTheSamePlaceOnEveryBase() {
        for (name, frames) in others {
            let other = profile(on: frames)
            let first = GuidePicture(reading: reading(so, carriedTo: so.frames), profile: so, aids: Self.allAids)
            let second = GuidePicture(reading: reading(so, carriedTo: frames), profile: other, aids: Self.allAids)
            for share in [SIMD2(0.2, 0.3), SIMD2(0.5, 0.5), SIMD2(0.9, 0.1)] {
                let a = first.projection.base(fromOperator: first.projection.point(aboveShare: share, up: 0.09))
                let b = second.projection.base(fromOperator: second.projection.point(aboveShare: share, up: 0.09))
                XCTAssertEqual(
                    simd_distance(b, TestFrames.carry(a, from: so.frames, to: frames)), 0, accuracy: 1e-12, name)
            }
        }
    }

    // MARK: The world and the base

    func testTheSO101TakesTheWorldAsTheBaseShiftedAsBefore() {
        for world in [SIMD3<Float>(0.005, -0.2, 0.1025), SIMD3(0.075, -0.2, 0.1035), SIMD3(-0.1, 0.3, 0)] {
            XCTAssertEqual(so.inBase(world: world), world - so.baseInWorld)
        }
    }

    /// An object seen in the world is the same place in every base: taken into the base and back out through the
    /// frames it is where it was, and a place in the world that is one metre up is one metre up along up.
    func testAWorldPositionComesIntoEveryBaseWhereItIs() {
        let world = SIMD3<Float>(0.075, -0.2, 0.1035)
        for (name, frames) in TestFrames.all {
            let p = profile(on: frames)
            let base = p.inBase(world: world)
            let back = frames.world(fromBase: SIMD3<Double>(base))
            XCTAssertEqual(simd_distance(SIMD3<Float>(back), world), 0, accuracy: 1e-6, name)
            let above = p.inBase(world: world + SIMD3(0, 0, 1))
            XCTAssertEqual(
                frames.height(of: SIMD3<Double>(above)) - frames.height(of: SIMD3<Double>(base)), 1, accuracy: 1e-6,
                name)
        }
    }

    // MARK: The work-area cue's floor

    /// The table stops the arm before the box's floor, on every base: the same answer, for a table under the floor
    /// and for one above it.
    func testTheFloorBelowTheTableIsTheSameQuestionOnEveryBase() {
        for (name, frames) in TestFrames.all {
            var p = profile(on: frames)
            XCTAssertTrue(p.workspaceFloorIsBelowTable, "\(name): the SO-101's table is above the box's floor")
            p.tableHeight = -0.1
            XCTAssertFalse(p.workspaceFloorIsBelowTable, "\(name): a table under the floor")
        }
    }

    // MARK: What the phone sends

    func testThePhonesMotionIsSentAsTheSO101DoesCarriedThroughTheLink() {
        let axes: [(right: SIMD3<Float>, forward: SIMD3<Float>)] = [
            (SIMD3(1, 0, 0), SIMD3(0, 0, -1)), (SIMD3(0, 0, 1), SIMD3(1, 0, 0)),
        ]
        for (name, frames) in others {
            for (right, forward) in axes {
                for world in [SIMD3<Float>(0.01, 0.02, 0.03), SIMD3(-0.02, 0.01, 0.04), SIMD3(0, 0.05, 0)] {
                    let first = LiveLinkController.serverOffset(
                        world, right: right, forward: forward, frames: so.frames)
                    let second = LiveLinkController.serverOffset(world, right: right, forward: forward, frames: frames)
                    let carried = SIMD3<Float>(
                        frames.link(
                            fromBase: TestFrames.carry(
                                so.frames.base(fromLink: SIMD3<Double>(first)), from: so.frames, to: frames)))
                    XCTAssertEqual(simd_distance(second, carried), 0, accuracy: 1e-7, name)
                }
            }
        }
    }
}
