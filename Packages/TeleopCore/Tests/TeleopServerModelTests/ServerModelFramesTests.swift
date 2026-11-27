import XCTest
import simd

@testable import TeleopCore
@testable import TeleopServerModel

/// The server model with another base: each of the six operator directions moves the tool along the base axis that
/// direction names, the table stops the jaw tips at the same place in the world, the grasp has the same tolerances
/// and the whole pick and place succeeds. The SO-101's frames are the reference; the others are bench arm B (base z
/// down, a turned world, no link flip) and an arm on its side.
final class ServerModelFramesTests: XCTestCase {
    private let so = TestFrames.so101

    private func bench(_ frames: Frames) throws -> Bench {
        Bench(try ServerModelConfig.s4Simulator.framed(by: frames, from: so))
    }

    private func point(_ state: JSONValue, _ key: String) throws -> SIMD3<Double> {
        let numbers = try XCTUnwrap(state[key]?.arrayValue?.compactMap(\.numberValue))
        XCTAssertEqual(numbers.count, 3, key)
        return SIMD3(numbers[0], numbers[1], numbers[2])
    }

    private func assertEqual(
        _ a: SIMD3<Double>, _ expected: SIMD3<Double>, accuracy: Double = 1e-6, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            simd_distance(a, expected), 0, accuracy: accuracy, "\(a) is not \(expected) \(message)", file: file,
            line: line)
    }

    func testEachDirectionMovesTheToolAlongTheBaseAxisItNames() throws {
        for (name, frames) in TestFrames.all {
            for direction in OperatorDirection.allCases {
                let bench = try bench(frames)
                let phone = bench.client()
                bench.wait(0.5)
                let before = try point(phone.lastState, "tool_pos")
                let armBefore = try point(phone.lastState, "ee_pos")
                phone.poseStart()
                // What the app sends: the direction's offset in the link's frame, 2 cm.
                let offset = frames.linkVector(direction) * 0.02
                phone.stream(for: 1.5) { phone.poseUpdate(link: offset) }
                phone.send("pose_stop")
                bench.wait(0.5)
                let tool = try point(phone.lastState, "tool_pos"), arm = try point(phone.lastState, "ee_pos")
                let along = frames.baseVector(direction) * 0.02
                assertEqual(tool - before, along, "tool, \(name) \(direction)")
                assertEqual(arm - armBefore, along, "arm, \(name) \(direction)")
            }
        }
    }

    /// Up is up in the world on every base, and a level direction keeps the height: the one thing the operator's view
    /// and the world share whichever way the base is mounted.
    func testUpIsUpInTheWorldOnEveryBase() throws {
        for (name, frames) in TestFrames.all {
            for direction in OperatorDirection.allCases {
                let bench = try bench(frames)
                let phone = bench.client()
                bench.wait(0.5)
                let before = try point(phone.lastState, "tool_pos")
                phone.poseStart()
                phone.stream(for: 1.5) { phone.poseUpdate(link: frames.linkVector(direction) * 0.02) }
                phone.send("pose_stop")
                bench.wait(0.5)
                let after = try point(phone.lastState, "tool_pos")
                let moved = bench.config.worldFromBase(after) - bench.config.worldFromBase(before)
                let expected: Double = direction == .up ? 0.02 : (direction == .down ? -0.02 : 0)
                XCTAssertEqual(moved.z, expected, accuracy: 1e-6, "\(name) \(direction)")
            }
        }
    }

    func testTheTableStopsTheJawTipsAtTheSameHeightInTheWorld() throws {
        for (name, frames) in TestFrames.all {
            let bench = try bench(frames)
            let phone = bench.client()
            bench.wait(0.5)
            phone.poseStart()
            phone.stream(for: 4) { phone.poseUpdate(link: frames.linkVector(.down) * 0.08) }
            phone.send("pose_stop")
            bench.wait(0.5)
            let pinch = try point(phone.lastState, "tool_pos")
            let config = bench.config
            XCTAssertEqual(
                config.worldFromBase(pinch).z, config.tableTopWorld + config.jawReachBelowPinch, accuracy: 1e-6, name)
        }
    }

    func testTheGraspHasTheSameTolerancesWhicheverWayTheBaseIsTurned() throws {
        // Offsets of the pinch point from the cube's centre, as the operator sees them, as the SO-101's own tests take
        // them: inside the tolerance, 1 cm to the side, 2.5 cm behind, 1.2 cm above.
        let cases: [(SIMD3<Double>, Bool)] = [
            (SIMD3(0.004, -0.003, 0.006), true), (SIMD3(0.010, 0, 0), false), (SIMD3(0, 0.025, 0), false),
            (SIMD3(0, 0, 0.012), false),
        ]
        for (name, frames) in TestFrames.all {
            for (offset, holds) in cases {
                let bench = try bench(frames)
                let phone = bench.client()
                let carried = TestFrames.carry(offset, from: so, to: frames)
                XCTAssertEqual(phone.closeJaws(offFromCube: carried), holds, "\(name) \(offset)")
            }
        }
    }

    func testThePickAndPlaceSucceedsOnEveryBase() throws {
        for (name, frames) in TestFrames.all {
            let bench = try bench(frames)
            let phone = bench.client()
            phone.carryCubeOntoGoal()
            let open = phone.gripperJog("open", seconds: 3, release: false)
            XCTAssertEqual(
                phone.ack(open).map { "\($0.status) \($0.reason)" }, "ok task_success", name)
            XCTAssertEqual(bench.model.state["task_success"], true, name)
        }
    }
}
