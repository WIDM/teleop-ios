import XCTest

@testable import TeleopCore
@testable import TeleopServerModel

/// The model refuses a configuration whose frames cannot be a base, and a turning pinch point on a base whose up is
/// not along world +z, when the configuration is built, with a sentence that says what is wrong.
final class ServerModelConfigFramesTests: XCTestCase {
    private let unit = (x: SIMD3<Double>(1, 0, 0), y: SIMD3<Double>(0, 1, 0), z: SIMD3<Double>(0, 0, 1))

    private func frames(
        shift: SIMD3<Double> = SIMD3(0, 0, 0.05), x: SIMD3<Double>? = nil, y: SIMD3<Double>? = nil,
        z: SIMD3<Double>? = nil, link: SIMD3<Double> = SIMD3(1, 1, -1)
    ) throws -> ServerModelConfig {
        try ServerModelConfig.s4Simulator.settingFrames(
            baseInWorld: shift, x: x ?? unit.x, y: y ?? unit.y, z: z ?? unit.z, linkSigns: link)
    }

    private func refusal(_ build: () throws -> ServerModelConfig, file: StaticString = #filePath, line: UInt = #line)
        -> [String]
    {
        do {
            _ = try build()
            XCTFail("was built", file: file, line: line)
            return []
        } catch let error as ServerModelConfig.Refusal {
            return error.sentences
        } catch {
            XCTFail("\(error)", file: file, line: line)
            return []
        }
    }

    func testEveryTestSetOfFramesBuildsAndTheDefaultHasNoFault() throws {
        XCTAssertEqual(ServerModelConfig.s4Simulator.faults(), [])
        for (name, set) in TestFrames.all {
            let config = try ServerModelConfig.s4Simulator.settingFrames(from: set)
            XCTAssertEqual(config.faults(), [], name)
            XCTAssertEqual(config.baseInWorld, set.baseInWorld, name)
            XCTAssertEqual(config.linkSigns, set.linkSigns, name)
        }
    }

    func testAnAxisThatIsNotAQuarterTurnIsRefused() {
        let diagonal = SIMD3<Double>(0.7071, 0.7071, 0)
        XCTAssertEqual(
            refusal { try frames(x: diagonal) },
            [
                "The base's x axis in the world must be a unit vector along one world axis (a quarter turn); it is "
                    + "(0.7071, 0.7071, 0.0)."
            ])
        XCTAssertEqual(refusal { try frames(z: SIMD3(0, 0, 2)) }.count, 1, "not a unit")
        XCTAssertEqual(refusal { try frames(y: .zero) }.count, 1, "no direction")
        XCTAssertEqual(refusal { try frames(x: SIMD3(1, 1, 0), y: SIMD3(0, 1, 1)) }.count, 2, "one for each axis")
    }

    func testTwoBaseAxesOnOneWorldAxisAreRefused() {
        XCTAssertEqual(
            refusal { try frames(y: unit.x) },
            ["The base's x, y and z axes must lie along three different world axes, one each."])
    }

    func testAMirrorImageIsRefused() {
        XCTAssertEqual(
            refusal { try frames(z: SIMD3(0, 0, -1)) },
            ["The base's axes in the world are a mirror image, not a turn: x cross y must be z."])
    }

    func testLinkSignsAndTheShiftAreChecked() {
        XCTAssertEqual(
            refusal { try frames(link: SIMD3(1, 2, -1)) },
            ["The link signs must each be 1 or -1; only a mirrored axis is supported."])
        XCTAssertEqual(
            refusal { try frames(shift: SIMD3(0, .infinity, 0.05)) },
            ["The base's place in the world must be finite numbers."])
    }

    func testATurningPinchPointNeedsUpAlongWorldPlusZ() throws {
        // Base z down (bench arm B) and base y up (an arm on its side): the turn is written for neither.
        for (name, set) in [("bench arm B", TestFrames.benchB), ("arm on its side", TestFrames.onItsSide)] {
            let framed = try ServerModelConfig.s4Simulator.settingFrames(from: set)
            let sentences = refusal { try framed.settingToolTurn(.s4Simulator) }
            XCTAssertEqual(sentences.count, 1, name)
            XCTAssertTrue(
                sentences[0].hasPrefix("The turning pinch point (toolTurn) needs the base's up along world +z"),
                "\(sentences)")
            // The other order says the same.
            let turning = try ServerModelConfig.s4Simulator.settingToolTurn(.s4Simulator)
            XCTAssertEqual(refusal { try turning.settingFrames(from: set) }, sentences, name)
        }
        let so101 = try ServerModelConfig.s4Simulator.settingFrames(from: TestFrames.so101)
        XCTAssertNotNil(try so101.settingToolTurn(.s4Simulator).toolTurn, "the SO-101's up is along +z")
        XCTAssertNil(try so101.settingToolTurn(nil).toolTurn)
    }

    func testABaseWhoseFramesAreRefusedDoesNotAlsoSayTheTurnIsWrong() throws {
        let turning = try ServerModelConfig.s4Simulator.settingToolTurn(.s4Simulator)
        XCTAssertEqual(
            refusal {
                try turning.settingFrames(
                    baseInWorld: .zero, x: unit.x, y: unit.x, z: unit.z, linkSigns: SIMD3(1, 1, 1))
            },
            ["The base's x, y and z axes must lie along three different world axes, one each."])
    }
}
