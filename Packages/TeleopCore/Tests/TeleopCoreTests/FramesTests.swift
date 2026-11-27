import XCTest

@testable import TeleopCore

final class FramesTests: XCTestCase {
    private func points(_ count: Int, seed: UInt64) -> [SIMD3<Double>] {
        var random = SplitMix64(seed: seed)
        return (0..<count).map { _ in
            SIMD3(random.uniform(-1, 1), random.uniform(-1, 1), random.uniform(-1, 1))
        }
    }

    // MARK: The SO-101's frames (the direction table and the link signs are pinned in OperatorFrameTests)

    func testTheSO101WorldIsTheBaseShiftedUp() {
        XCTAssertEqual(TestFrames.so101.base(fromWorld: SIMD3(0.1, -0.2, 0.3)), SIMD3(0.1, -0.2, 0.25))
    }

    // MARK: Both sets

    func testEveryDirectionIsOneUnitAlongItsAxisAndTheOperatorSeesIt() {
        let seen: [OperatorDirection: SIMD3<Double>] = [
            .right: SIMD3(1, 0, 0), .left: SIMD3(-1, 0, 0), .forward: SIMD3(0, 1, 0), .back: SIMD3(0, -1, 0),
            .up: SIMD3(0, 0, 1), .down: SIMD3(0, 0, -1),
        ]
        for (name, frames) in TestFrames.all {
            for direction in OperatorDirection.allCases {
                let v = frames.baseVector(direction)
                XCTAssertEqual(abs(v.x) + abs(v.y) + abs(v.z), 1, "\(name) \(direction)")
                XCTAssertEqual(frames.operatorPoint(v), seen[direction], "\(name) \(direction)")
            }
        }
    }

    func testOppositeDirectionsCancel() {
        let pairs: [(OperatorDirection, OperatorDirection)] = [(.forward, .back), (.left, .right), (.up, .down)]
        for (name, frames) in TestFrames.all {
            for (a, b) in pairs {
                XCTAssertEqual(frames.linkVector(a) + frames.linkVector(b), .zero, "\(name) \(a) and \(b)")
            }
        }
    }

    func testOperatorToBaseToOperatorRoundTrips() {
        for (name, frames) in TestFrames.all {
            for p in points(200, seed: 1) {
                XCTAssertEqual(frames.operatorPoint(frames.base(fromOperator: p)), p, "\(name) \(p)")
                XCTAssertEqual(frames.base(fromOperator: frames.operatorPoint(p)), p, "\(name) \(p)")
            }
        }
    }

    func testBaseToLinkToBaseRoundTrips() {
        for (name, frames) in TestFrames.all {
            for p in points(200, seed: 2) {
                XCTAssertEqual(frames.base(fromLink: frames.link(fromBase: p)), p, "\(name) \(p)")
                XCTAssertEqual(frames.link(fromBase: frames.base(fromLink: p)), p, "\(name) \(p)")
            }
        }
    }

    func testWorldToBaseToWorldRoundTrips() {
        for (name, frames) in TestFrames.all {
            for p in points(200, seed: 3) {
                let back = frames.world(fromBase: frames.base(fromWorld: p))
                XCTAssertEqual(back.x, p.x, accuracy: 1e-12, "\(name) \(p)")
                XCTAssertEqual(back.y, p.y, accuracy: 1e-12, "\(name) \(p)")
                XCTAssertEqual(back.z, p.z, accuracy: 1e-12, "\(name) \(p)")
                let there = frames.base(fromWorld: frames.world(fromBase: p))
                XCTAssertEqual(there.x, p.x, accuracy: 1e-12, "\(name) \(p)")
                XCTAssertEqual(there.y, p.y, accuracy: 1e-12, "\(name) \(p)")
                XCTAssertEqual(there.z, p.z, accuracy: 1e-12, "\(name) \(p)")
            }
        }
    }

    func testTheSinglePrecisionWorldToBaseAgreesWithTheDoubleOne() {
        for (name, frames) in TestFrames.all {
            for p in points(100, seed: 4) {
                let single = frames.base(fromWorld: SIMD3<Float>(p))
                let double = frames.base(fromWorld: SIMD3<Double>(SIMD3<Float>(p)))
                for axis in 0..<3 { XCTAssertEqual(Double(single[axis]), double[axis], accuracy: 1e-6, "\(name)") }
            }
        }
    }

    /// The world's up is the operator's up on both sets: a point one metre up in the world is one metre up as the
    /// operator sees it, wherever the base is turned.
    func testWorldUpIsHeightOnBothSets() {
        for (name, frames) in TestFrames.all {
            let low = frames.base(fromWorld: SIMD3(0.3, 0.2, 0.1)), high = frames.base(fromWorld: SIMD3(0.3, 0.2, 1.1))
            XCTAssertEqual(frames.height(of: high) - frames.height(of: low), 1, accuracy: 1e-12, "\(name)")
        }
    }

    func testHeightIsThePartAlongUpAndCanBeSet() {
        for (name, frames) in TestFrames.all {
            XCTAssertEqual(frames.height(of: frames.upVector), 1, "\(name)")
            for p in points(50, seed: 5) {
                let moved = frames.settingHeight(0.4, of: p)
                XCTAssertEqual(frames.height(of: moved), 0.4, accuracy: 1e-12, "\(name)")
                XCTAssertEqual(frames.level(moved), frames.level(p), "\(name) the place across does not change")
                XCTAssertEqual(frames.height(of: frames.level(p)), 0, "\(name)")
            }
        }
    }

    func testTheOperatorsOffsetMatchesTheButtons() {
        for (name, frames) in TestFrames.all {
            let offset = frames.linkOffset(right: 0.01, forward: 0.02, up: 0.03)
            XCTAssertEqual(
                offset,
                frames.linkVector(.right) * 0.01 + frames.linkVector(.forward) * 0.02 + frames.linkVector(.up) * 0.03,
                "\(name)")
            XCTAssertEqual(frames.linkOffset(right: -1, forward: 0, up: 0), frames.linkVector(.left), "\(name)")
            XCTAssertEqual(frames.linkOffset(right: 0, forward: -1, up: 0), frames.linkVector(.back), "\(name)")
            XCTAssertEqual(frames.linkOffset(right: 0, forward: 0, up: -1), frames.linkVector(.down), "\(name)")
        }
        XCTAssertEqual(
            TestFrames.so101.linkOffset(right: 0.01, forward: 0.02, up: 0.03), SIMD3(-0.01, -0.02, -0.03),
            "the phone's mapping: each negated")
    }

    func testCarryingThroughTheFramesKeepsWhatTheOperatorSees() {
        for p in points(50, seed: 6) {
            let there = TestFrames.carry(p, from: TestFrames.so101, to: TestFrames.benchB)
            XCTAssertEqual(
                TestFrames.benchB.operatorPoint(there), TestFrames.so101.operatorPoint(p), "same view")
            XCTAssertEqual(TestFrames.carry(there, from: TestFrames.benchB, to: TestFrames.so101), p)
        }
    }

    // MARK: Validation

    func testBothSetsAreValid() {
        for (name, frames) in TestFrames.all { XCTAssertEqual(frames.faults(), [], name) }
    }

    func testAMirrorImageOfTheOperatorsViewIsRefused() {
        var frames = TestFrames.so101
        frames.left = frames.left.reversed
        XCTAssertEqual(
            frames.faults(),
            [
                "robot.directions: forward, left and up make a mirror image of the operator's view, not a turn of "
                    + "the base. Flip the sign of one of the three."
            ])
    }

    /// One wrong sign, on any of the three, is a mirror image and is caught; two wrong signs are a half turn and are
    /// valid (the direction check on a new arm catches those).
    func testOneWrongSignIsRefusedAndTwoAreNot() {
        for (name, valid) in TestFrames.all {
            var f = valid
            f.forward = f.forward.reversed
            XCTAssertEqual(f.faults().count, 1, "\(name) forward")
            f = valid
            f.up = f.up.reversed
            XCTAssertEqual(f.faults().count, 1, "\(name) up")
            f = valid
            f.forward = f.forward.reversed
            f.left = f.left.reversed
            XCTAssertEqual(f.faults(), [], "\(name) forward and left both flipped is a valid half turn")
        }
    }

    func testTwoDirectionsOnOneAxisAreRefused() {
        var frames = TestFrames.so101
        frames.left = SignedAxis(.y, 1)
        XCTAssertEqual(
            frames.faults(),
            [
                "robot.directions: forward, left and up must lie along three different base axes, one each; "
                    + "they are forward -y, left +y, up +z."
            ])
    }

    func testLinkSignsThatAreNotPlusOrMinusOneAreRefused() {
        for bad in [0.0, 2, 0.5, .nan] {
            var frames = TestFrames.so101
            frames.linkSigns = SIMD3(1, bad, -1)
            XCTAssertEqual(
                frames.faults(), ["server.link_signs must each be 1 or -1; only a mirrored axis is supported."],
                "\(bad)")
        }
    }

    func testAWorldMirrorImageIsRefused() {
        var frames = TestFrames.benchB
        frames.worldTurn.z = frames.worldTurn.z.reversed
        XCTAssertEqual(
            frames.faults(),
            [
                "scene.base_axes_in_world is a mirror image, not a turn: the base's x cross y must be its z. "
                    + "Flip the sign of one of the three."
            ])
    }

    func testTwoBaseAxesOnOneWorldAxisAreRefused() {
        var frames = TestFrames.so101
        frames.worldTurn.y = SignedAxis(.x, 1)
        XCTAssertEqual(
            frames.faults(),
            [
                "scene.base_axes_in_world: x, y and z must lie along three different world axes, one each; "
                    + "they are x +x, y +x, z +z."
            ])
    }

    func testANonFiniteShiftIsRefused() {
        var frames = TestFrames.so101
        frames.baseInWorld.y = .infinity
        XCTAssertEqual(frames.faults(), ["scene.base_in_world_m must be finite numbers."])
    }

    func testASignOtherThanOneOrMinusOneIsRefusedWithASentenceForEachField() {
        for bad in [2.0, -2, 0, 0.5, .nan] {
            var frames = TestFrames.so101
            frames.forward = SignedAxis(.y, bad)
            XCTAssertEqual(
                frames.faults(),
                ["robot.directions.forward must point one way along its axis: a sign of 1 or -1, not \(bad)."],
                "forward \(bad)")
            frames = TestFrames.so101
            frames.up = SignedAxis(.z, bad)
            XCTAssertEqual(
                frames.faults(),
                ["robot.directions.up must point one way along its axis: a sign of 1 or -1, not \(bad)."],
                "up \(bad)")
            frames = TestFrames.so101
            frames.worldTurn.y = SignedAxis(.y, bad)
            XCTAssertEqual(
                frames.faults(),
                ["scene.base_axes_in_world.y must point one way along its axis: a sign of 1 or -1, not \(bad)."],
                "world y \(bad)")
        }
        var frames = TestFrames.so101
        frames.forward = SignedAxis(.y, -2)
        frames.left = SignedAxis(.x, 3)
        XCTAssertEqual(frames.faults().count, 2, "one sentence for each field")
    }

    func testUpMustBeTheBaseAxisThatLiesAlongWorldUp() {
        for (name, valid) in TestFrames.all {
            // Up is declared one way and the world turn puts world z along the other way.
            var f = valid
            f.up = f.up.reversed
            f.left = f.left.reversed  // keeps the directions a turn, so only the two fields disagree
            XCTAssertEqual(f.faults().count, 1, "\(name) up reversed")
            XCTAssertTrue(f.faults()[0].hasPrefix("robot.directions.up is "), "\(name): \(f.faults())")
            XCTAssertTrue(f.faults()[0].contains("scene.base_axes_in_world"), "\(name): \(f.faults())")
        }
        // The SO-101 with its base turned onto its side in the world while up still says z.
        var f = TestFrames.so101
        f.worldTurn = WorldTurn(x: SignedAxis(.x, 1), y: SignedAxis(.z, 1), z: SignedAxis(.y, -1))
        XCTAssertEqual(
            f.faults(),
            [
                "robot.directions.up is +z, but scene.base_axes_in_world puts base +y along world +z. They must name "
                    + "the same base axis, the same way."
            ])
    }

    func testFramesRoundTripThroughCodable() throws {
        for (name, frames) in TestFrames.all {
            let data = try JSONEncoder().encode(frames)
            XCTAssertEqual(try JSONDecoder().decode(Frames.self, from: data), frames, name)
        }
        let text = String(decoding: try JSONEncoder().encode(TestFrames.so101.forward), as: UTF8.self)
        XCTAssertEqual(text, "\"-y\"", "an axis is written as its text")
        XCTAssertThrowsError(try JSONDecoder().decode(SignedAxis.self, from: Data("\"+w\"".utf8)))
    }

    func testASignedAxisReadsAndWritesItsText() {
        for text in ["+x", "-x", "+y", "-y", "+z", "-z"] { XCTAssertEqual(SignedAxis(text: text)?.text, text) }
        for bad in ["x", "+", "++x", "+w", "up", "", "+xy", "1", "-0", " +x"] {
            XCTAssertNil(SignedAxis(text: bad), bad)
        }
    }
}
