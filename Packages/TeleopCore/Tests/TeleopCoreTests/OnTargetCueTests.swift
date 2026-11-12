import XCTest
@testable import TeleopCore

/// When the on-target cue plays: once as "on target" turns true, never again until the pinch point has left a window
/// half as large again, or the jaws closed, the scene reset or a target appeared.
final class OnTargetCueTests: XCTestCase {
    /// The S4 simulator's window: 6 mm across, 8 mm in height.
    private let window = SIMD2(0.006, 0.008)
    private var cue: OnTargetCue!
    private var clock = 0

    override func setUp() {
        cue = OnTargetCue(window: window)
        clock = 0
    }

    /// One look, 200 ms after the last. True when the cue played.
    @discardableResult
    private func look(
        across: Double?, height: Double = 0, approximate: Bool = false, holding: Bool = false, taskAid: Bool = true,
        jawsOpen: Bool = true, stopped: Bool = false
    ) -> Bool {
        clock += 200
        let gap = across.map { SIMD2($0, height) }
        return cue.observe(
            OnTargetCue.Look(gap: gap, approximate: approximate, holding: holding, taskAid: taskAid, jawsOpen: jawsOpen, stopped: stopped),
            at: clock
        )
    }

    func testItPlaysOnceAsOnTargetTurnsTrue() {
        XCTAssertFalse(look(across: 0.02))
        XCTAssertFalse(look(across: 0.0065), "just outside")
        XCTAssertTrue(look(across: 0.0055))
        XCTAssertEqual(cue.playedAtMs, clock)
        for _ in 0..<20 { XCTAssertFalse(look(across: 0.001)) }
        XCTAssertFalse(look(across: 0.0, height: -0.008), "on the window's edge in height is still inside")
    }

    func testTheWindowsEdgesCountAsInside() {
        XCTAssertTrue(OnTargetCue.inside(SIMD2(0.006, 0.008), window: window))
        XCTAssertTrue(OnTargetCue.inside(SIMD2(0.006, -0.008), window: window))
        XCTAssertFalse(OnTargetCue.inside(SIMD2(0.0061, 0), window: window))
        XCTAssertFalse(OnTargetCue.inside(SIMD2(0, -0.0081), window: window))
    }

    /// Leaving the window but not the one 1.5 times as large does not arm it again; leaving that does.
    func testItIsNotPlayedAgainInsideTheHysteresis() {
        XCTAssertTrue(look(across: 0.003))
        XCTAssertFalse(look(across: 0.0089), "out of the window, inside 9 mm")
        XCTAssertFalse(look(across: 0.003))
        XCTAssertFalse(look(across: 0.0, height: 0.0119), "out in height, inside 12 mm")
        XCTAssertFalse(look(across: 0.0, height: 0.002))
        XCTAssertFalse(look(across: 0.0091), "past 9 mm across")
        XCTAssertTrue(look(across: 0.002))
        XCTAssertFalse(look(across: 0.0, height: -0.0121), "past 12 mm below")
        XCTAssertTrue(look(across: 0.0, height: -0.004))
    }

    func testItNeverPlaysWhileTheMarkerIsApproximate() {
        for _ in 0..<5 { XCTAssertFalse(look(across: 0.001, approximate: true)) }
        XCTAssertTrue(look(across: 0.001), "the estimate became close enough: on target turns true")
        XCTAssertFalse(look(across: 0.001, approximate: true))
        XCTAssertFalse(look(across: 0.001))
    }

    func testItNeverPlaysWithTheTaskAidOff() {
        for _ in 0..<5 { XCTAssertFalse(look(across: 0.001, taskAid: false)) }
        XCTAssertTrue(look(across: 0.001), "turned on while on target")
    }

    func testItNeverPlaysWithoutATargetWhileTheStopIsLatchedOrWhileHolding() {
        for _ in 0..<5 { XCTAssertFalse(look(across: nil)) }
        for _ in 0..<5 { XCTAssertFalse(look(across: 0.001, stopped: true)) }
        for _ in 0..<5 { XCTAssertFalse(look(across: 0.001, holding: true)) }
        XCTAssertNil(cue.playedAtMs)
    }

    /// The jaws must be open; a close arms it again, so opening on the target after a miss plays it.
    func testAfterACloseOpeningOnTheTargetPlaysAgain() {
        XCTAssertFalse(look(across: 0.001, jawsOpen: false), "reached with the jaws shut")
        XCTAssertTrue(look(across: 0.001), "opened on the target")
        XCTAssertFalse(look(across: 0.001, jawsOpen: false), "closed on nothing")
        XCTAssertTrue(look(across: 0.001), "opened again")
    }

    /// Jaws the server says nothing about may be shut: no cue. Nor are they a close: on the target, open, unknown,
    /// open again is still one approach.
    func testJawsOfUnknownStateNeitherPlayNorArmIt() {
        clock += 200
        XCTAssertFalse(cue.observe(.init(gap: SIMD2(0.001, 0), approximate: false, holding: false, taskAid: true, jawsOpen: nil, stopped: false), at: clock))
        XCTAssertTrue(look(across: 0.001))
        clock += 200
        XCTAssertFalse(cue.observe(.init(gap: SIMD2(0.001, 0), approximate: false, holding: false, taskAid: true, jawsOpen: nil, stopped: false), at: clock))
        XCTAssertFalse(look(across: 0.001))
    }

    func testASceneResetOrANewTargetArmsItAgain() {
        XCTAssertTrue(look(across: 0.001))
        cue.rearm()
        XCTAssertTrue(look(across: 0.001))
        XCTAssertFalse(look(across: nil))
        XCTAssertTrue(look(across: 0.001), "a target reported after none")
    }

    /// A pick-and-place as the script does it, with a miss first: once per approach to the target. Letting go over the
    /// goal leaves the open jaws on the object, which is on target again after the close.
    func testOncePerApproachInAScriptedPickAndPlace() {
        var plays: [String: Int] = [:]
        var played = 0
        func counted(
            across: Double?, height: Double = 0, approximate: Bool = false, holding: Bool = false, jawsOpen: Bool = true
        ) {
            if look(across: across, height: height, approximate: approximate, holding: holding, jawsOpen: jawsOpen) { played += 1 }
        }
        func count(_ name: String, _ looks: () -> Void) {
            played = 0
            looks()
            plays[name] = played
        }

        count("after the reset") {
            for _ in 0..<5 { counted(across: 0.037, height: 0.02, approximate: true, jawsOpen: false) }
        }
        count("open far away") {
            for _ in 0..<5 { counted(across: 0.037, height: 0.02, approximate: true) }
        }
        count("first approach, from above, landing with a wobble") {
            for step in stride(from: 30, through: 0, by: -1) {
                let height = Double(step) / 1000
                counted(across: 0.004, height: height, approximate: height > 0.0035)
            }
            for wobble in [0.0055, 0.0068, 0.0049, 0.0072, 0.005, 0.0061, 0.0045] { counted(across: wobble) }
        }
        count("the miss: closed on nothing") {
            for _ in 0..<5 { counted(across: 0.0045, jawsOpen: false) }
        }
        count("opened again on the target") {
            for _ in 0..<5 { counted(across: 0.0045) }
        }
        count("backed off 2 cm and came back") {
            for step in 0...20 { counted(across: 0.0045 + Double(step) / 1000) }
            for step in stride(from: 20, through: 0, by: -1) { counted(across: Double(step) / 1000) }
        }
        count("the grasp, lift and carry") {
            for _ in 0..<5 { counted(across: 0.0, jawsOpen: false) }
            for _ in 0..<30 { counted(across: 0.0005, holding: true, jawsOpen: false) }
        }
        count("let go over the goal") {
            for _ in 0..<5 { counted(across: 0.0005, height: 0.002) }
        }
        count("lift away") {
            for step in 0...30 { counted(across: 0.0005, height: 0.002 + Double(step) / 1000) }
        }

        XCTAssertEqual(plays["after the reset"], 0)
        XCTAssertEqual(plays["open far away"], 0)
        XCTAssertEqual(plays["first approach, from above, landing with a wobble"], 1)
        XCTAssertEqual(plays["the miss: closed on nothing"], 0)
        XCTAssertEqual(plays["opened again on the target"], 1)
        XCTAssertEqual(plays["backed off 2 cm and came back"], 1)
        XCTAssertEqual(plays["the grasp, lift and carry"], 0)
        XCTAssertEqual(plays["let go over the goal"], 1)
        XCTAssertEqual(plays["lift away"], 0)
    }
}
