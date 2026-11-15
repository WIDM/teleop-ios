import simd
import TeleopCore
import XCTest
@testable import Teleop

/// The guide's aids in the picture: the line naming the side the commanded place is outside on, "lowest" on the height
/// and the lowest line from behind, the shadow's lift, and which way is forward and up. Each appears only with its own
/// aid; no aids, or all of them off, is version 1.0.1's picture.
final class GuidePictureAssistTests: XCTestCase {
    private let profile = RobotProfile.so101Simulator
    private var centre: SIMD3<Float> { (profile.workspaceMin + profile.workspaceMax) / 2 }
    private var table: Double { Double(profile.tableHeight) }
    private var savedLanguage = L10n.language

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.language
    }

    override func tearDown() {
        L10n.language = savedLanguage
        super.tearDown()
    }

    private func reading(
        _ pinch: SIMD3<Float>? = nil, outsideOn side: OperatorDirection? = nil, lowestGripperZ: Float? = nil,
        boxShift: SIMD3<Float> = .zero
    ) -> ArmReading {
        let pinch = pinch ?? centre
        var reading = ArmReading(
            pinchPoint: pinch, commanded: pinch + SIMD3(0, -0.03, 0), jawOpening: 0.6, wristTurnDeg: 88,
            wristTiltDeg: -4, target: nil, goal: nil, gripping: false)
        reading.boxShift = boxShift
        reading.commandOutside = side
        reading.lowestGripperZ = lowestGripperZ
        return reading
    }

    private func picture(_ reading: ArmReading, _ aids: GuideAids?) -> GuidePicture {
        GuidePicture(reading: reading, profile: profile, aids: aids)
    }

    private static let none = GuideAids(
        workAreaWords: false, lowestCue: false, shadow: false, directionLabels: false, widerOnTarget: false)

    private static func only(_ aid: WritableKeyPath<GuideAids, Bool>) -> GuideAids {
        var aids = none
        aids[keyPath: aid] = true
        return aids
    }

    /// The gripper-link height whose pinch height, with no measured offset, is `pinchZ`.
    private func gripperZ(atPinch pinchZ: Float) -> Float { pinchZ - profile.toolOffset.z }

    func testEveryAidIsOnInAll() {
        let all = GuideAids.all
        XCTAssertTrue(all.workAreaWords)
        XCTAssertTrue(all.lowestCue)
        XCTAssertTrue(all.shadow)
        XCTAssertTrue(all.directionLabels)
        XCTAssertTrue(all.widerOnTarget)
    }

    /// No aids, or every aid off, draws and says exactly what version 1.0.1 does, even for a reading that carries the
    /// side and the lowest height.
    func testNoAidsDrawsOneZeroOne() {
        let carrying = [
            reading(outsideOn: .forward, lowestGripperZ: gripperZ(atPinch: centre.z)),
            reading(SIMD3(profile.workspaceMin.x - 0.03, centre.y, centre.z), outsideOn: .right),
            reading(lowestGripperZ: gripperZ(atPinch: centre.z - 0.001), boxShift: SIMD3(0.004, -0.003, -0.006)),
        ]
        for carried in carrying {
            var plain = carried
            plain.commandOutside = nil
            plain.lowestGripperZ = nil
            let version101 = GuidePicture(reading: plain, profile: profile)
            XCTAssertEqual(GuidePicture(reading: carried, profile: profile), version101)
            XCTAssertEqual(picture(carried, nil), version101)
            XCTAssertEqual(picture(carried, Self.none), version101, "every aid off is no aids")
            XCTAssertNil(version101.lowestY)
            XCTAssertNil(version101.lift)
            XCTAssertFalse(version101.directionLabels)
        }
    }

    /// The line names the side while the reading has one, and is placed just before "Outside the work area", which
    /// stays last; it needs its own aid.
    func testTheCommandOutsideLineIsShownExactlyWhileOutsideAndJustBeforeOutside() {
        let inside = picture(reading(outsideOn: .forward), .all)
        XCTAssertEqual(inside.lines.last, .commandOutside(.forward))
        XCTAssertEqual(inside.lines.filter { $0 == .commandOutside(.forward) }.count, 1)
        let pinchOut = picture(reading(SIMD3(profile.workspaceMin.x - 0.03, centre.y, centre.z), outsideOn: .up), .all)
        XCTAssertEqual(pinchOut.lines.suffix(2), [.commandOutside(.up), .outside])
        XCTAssertFalse(picture(reading(), .all).lines.contains { if case .commandOutside = $0 { true } else { false } })
        for side in OperatorDirection.allCases {
            let told = picture(reading(outsideOn: side), Self.only(\.workAreaWords))
            XCTAssertEqual(told.lines.last, .commandOutside(side))
            XCTAssertEqual(
                picture(reading(outsideOn: side), Self.only(\.lowestCue)).lines,
                picture(reading(), nil).lines, "\(side) without its aid")
        }
    }

    /// Within 2 mm of the lowest height a stall reached, above or below, the height says "lowest", with the same
    /// number; farther off it is the plain height. The lowest height is kept for the gripper link and moved by the
    /// reading's own offset, as the ring and the box are.
    func testTheHeightSaysLowestWithinTwoMillimetresOfTheLowestHeight() {
        let pinch = SIMD3(centre.x, centre.y, Float(table) + 0.02)
        let plain = picture(reading(pinch), nil).lines
        guard case .height(let cm) = plain[0] else { return XCTFail("\(plain)") }
        for (offBy, lowest) in [(0.0015, true), (-0.0015, true), (0.0025, false), (-0.0025, false)] {
            let lines = picture(reading(pinch, lowestGripperZ: gripperZ(atPinch: pinch.z + Float(offBy))), .all).lines
            XCTAssertEqual(lines[0], lowest ? .heightLowest(cm: cm) : .height(cm: cm), "\(offBy)")
            XCTAssertEqual(Array(lines.dropFirst()), Array(plain.dropFirst()), "\(offBy)")
        }
        let shift = SIMD3<Float>(0.004, -0.003, -0.006)
        let shifted = reading(pinch, lowestGripperZ: pinch.z - profile.toolOffset.z - shift.z, boxShift: shift)
        XCTAssertEqual(picture(shifted, .all).lines[0], .heightLowest(cm: cm), "moved by the measured offset")
        let near = reading(pinch, lowestGripperZ: gripperZ(atPinch: pinch.z))
        XCTAssertEqual(picture(near, Self.only(\.shadow)).lines[0], .height(cm: cm), "without its aid")
    }

    /// From behind, a line at the pinch height of the stall: the gripper-link height plus the reading's own offset,
    /// placed through the picture's projection, between the box's top and the table, and on the view.
    func testTheLowestLineIsDrawnAtThePinchHeightOfTheStall() throws {
        let shift = SIMD3<Float>(0.004, -0.003, -0.006)
        let stall = gripperZ(atPinch: Float(table) + 0.005) - shift.z
        let p = picture(reading(lowestGripperZ: stall, boxShift: shift), .all)
        let lowestY = try XCTUnwrap(p.lowestY)
        let pinchZ = Double(stall) + Double((profile.toolOffset + shift).z)
        XCTAssertEqual(pinchZ, table + 0.005, accuracy: 1e-6)
        XCTAssertEqual(lowestY, p.projection.behind(SIMD3(0, 0, pinchZ)).y, accuracy: 1e-12)
        XCTAssertLessThan(lowestY, p.tableY, "above the table")
        XCTAssertGreaterThan(lowestY, p.boxBehind.minY, "below the box's top")
        XCTAssertEqual(picture(reading(lowestGripperZ: 5), .all).lowestY, 0, "kept on the view")
        XCTAssertNil(picture(reading(), .all).lowestY, "no stall yet")
        XCTAssertNil(picture(reading(lowestGripperZ: stall), Self.only(\.shadow)).lowestY, "without its aid")
        XCTAssertNotNil(picture(reading(lowestGripperZ: stall), Self.only(\.lowestCue)).lowestY)
    }

    /// The shadow's lift: the pinch height above the table over the box's height above it, 0 at the table, 1 at the
    /// box's top, kept between them; nil without its aid.
    func testTheLiftIsZeroAtTheTableOneAtTheBoxTopAndKeptBetween() throws {
        let top = profile.workspaceMax.z
        let cases: [(Float, Double)] = [
            (profile.tableHeight, 0), (top, 1), ((profile.tableHeight + top) / 2, 0.5), (top + 0.05, 1),
            (profile.tableHeight - 0.01, 0),
        ]
        for (z, lift) in cases {
            let p = picture(reading(SIMD3(centre.x, centre.y, z)), Self.only(\.shadow))
            XCTAssertEqual(try XCTUnwrap(p.lift), lift, accuracy: 1e-6, "\(z)")
        }
        XCTAssertNil(picture(reading(), Self.only(\.directionLabels)).lift)
    }

    func testTheDirectionLabelsFollowTheirAid() {
        XCTAssertTrue(picture(reading(), Self.only(\.directionLabels)).directionLabels)
        XCTAssertTrue(picture(reading(), .all).directionLabels)
        XCTAssertFalse(picture(reading(), Self.only(\.shadow)).directionLabels)
        XCTAssertFalse(picture(reading(), nil).directionLabels)
    }

    /// Each aid changes only its own part: everything else equals the no-aids picture.
    func testEachAidChangesOnlyItsOwnPart() {
        let carried = reading(outsideOn: .back, lowestGripperZ: gripperZ(atPinch: centre.z))
        let version101 = picture(carried, nil)
        let shadow = picture(carried, Self.only(\.shadow))
        XCTAssertEqual(shadow.lines, version101.lines)
        XCTAssertNil(shadow.lowestY)
        XCTAssertFalse(shadow.directionLabels)
        let labels = picture(carried, Self.only(\.directionLabels))
        XCTAssertEqual(labels.lines, version101.lines)
        XCTAssertNil(labels.lift)
        let wider = picture(carried, Self.only(\.widerOnTarget))
        XCTAssertEqual(wider, version101, "no wider window in the profile: nothing changes")
        let workArea = picture(carried, Self.only(\.workAreaWords))
        XCTAssertEqual(workArea.lines, version101.lines + [.commandOutside(.back)])
        XCTAssertNil(workArea.lowestY)
        XCTAssertNil(workArea.lift)
        XCTAssertEqual(workArea.pinch, version101.pinch)
        XCTAssertEqual(workArea.commanded, version101.commanded)
    }

    /// The new read-outs in both languages.
    func testTheNewLinesInBothLanguages() {
        L10n.language = .en
        XCTAssertEqual(GuideWords.text(.commandOutside(.forward)), "Asking outside the work area: too far forward")
        XCTAssertEqual(GuideWords.text(.commandOutside(.down)), "Asking outside the work area: too low")
        XCTAssertEqual(GuideWords.text(.heightLowest(cm: 0.5)), "Height 0.5 cm · lowest")
        L10n.language = .zhHant
        XCTAssertEqual(GuideWords.text(.commandOutside(.left)), "要去的位置超出工作範圍：太靠左")
        XCTAssertEqual(GuideWords.text(.commandOutside(.up)), "要去的位置超出工作範圍：太高")
        XCTAssertEqual(GuideWords.text(.heightLowest(cm: 0.5)), "離桌面 0.5 公分 · 最低點")
        var said = Set<String>()
        for side in OperatorDirection.allCases { said.insert(GuideWords.text(.commandOutside(side))) }
        XCTAssertEqual(said.count, 6, "each side has its own words")
        XCTAssertEqual(GuideView.identifier(.commandOutside(.back)), "readout.command_outside")
        XCTAssertEqual(GuideView.identifier(.heightLowest(cm: 1)), "readout.height")
    }
}
