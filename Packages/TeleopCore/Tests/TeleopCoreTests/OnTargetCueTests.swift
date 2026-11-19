import XCTest
@testable import TeleopCore

/// When the on-target cue plays: once as "on target" turns true, never again until the pinch point has left a window
/// half as large again, the scene reset, a target appeared, or the jaws closed and opened again on a target they never
/// lifted.
final class OnTargetCueTests: XCTestCase {
    /// The S4 simulator's window: 6 mm across, 8 mm in height.
    private let window = SIMD2(0.006, 0.008)
    private var cue: OnTargetCue!
    private var clock = 0

    override func setUp() {
        cue = OnTargetCue(window: window)
        clock = 0
    }

    /// One look, 200 ms after the last. True when the cue played. The pinch point is `across` from the target and
    /// `height` above it; the target is at `target`, the origin unless said.
    @discardableResult
    private func look(
        across: Double?, height: Double = 0, target: SIMD3<Double> = .zero, approximate: Bool = false,
        holding: Bool = false, taskAid: Bool = true, jawsOpen: Bool? = true, stopped: Bool = false
    ) -> Bool {
        clock += 200
        let gap = across.map { SIMD2($0, height) }
        return cue.observe(
            OnTargetCue.Look(
                gap: gap, target: across.map { _ in target }, approximate: approximate, holding: holding,
                taskAid: taskAid, jawsOpen: jawsOpen, stopped: stopped
            ),
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
        XCTAssertFalse(look(across: 0.001, jawsOpen: nil))
        XCTAssertTrue(look(across: 0.001))
        XCTAssertFalse(look(across: 0.001, jawsOpen: nil))
        XCTAssertFalse(look(across: 0.001))
    }

    /// Holding the target ends the approach. Jaws that lifted it, carried it away and let go of it elsewhere, where the
    /// open jaws are on it again, play nothing, whether or not it was felt on the way in; leaving the larger window arms
    /// it.
    func testLettingGoOfACarriedTargetPlaysNothing() {
        for feltOnTheWayIn in [true, false] {
            setUp()
            XCTAssertEqual(look(across: feltOnTheWayIn ? 0.002 : 0.007), feltOnTheWayIn)
            XCTAssertFalse(look(across: 0.0, jawsOpen: false), "closed; the closing jaws centre the target")
            for step in 0...20 {
                XCTAssertFalse(
                    look(across: 0.0, target: SIMD3(Double(step) / 200, 0, 0.02), holding: true, jawsOpen: false))
            }
            let goal = SIMD3(0.1, 0, 0.0)
            XCTAssertFalse(
                look(across: 0.0, target: goal, jawsOpen: false), "the open press ends the hold before the label")
            for _ in 0..<5 { XCTAssertFalse(look(across: 0.0, target: goal), "opened on the target, over the goal") }
            XCTAssertFalse(look(across: 0.0, height: 0.013, target: goal), "lifted past 12 mm")
            XCTAssertTrue(look(across: 0.0, target: goal), "a new approach")
        }
    }

    /// A grasp that took hold but did not lift, or one that touched the target a little off it: the jaws open again
    /// on a target they never lifted, and arriving on it is felt.
    func testOpeningWhereAHoldingCloseHappenedArmsItAgain() {
        XCTAssertTrue(look(across: 0.002))
        XCTAssertFalse(look(across: 0.002, jawsOpen: false))
        for _ in 0..<5 { XCTAssertFalse(look(across: 0.002, holding: true, jawsOpen: false)) }
        XCTAssertTrue(look(across: 0.002), "opened where it closed, still on the target")

        XCTAssertFalse(look(across: 0.0075), "off the target, inside 9 mm: not armed")
        XCTAssertFalse(look(across: 0.0075, jawsOpen: false))
        for _ in 0..<5 { XCTAssertFalse(look(across: 0.0075, holding: true, jawsOpen: false)) }
        XCTAssertFalse(look(across: 0.0075), "opened, 7.5 mm off")
        XCTAssertTrue(look(across: 0.003), "nudged onto the target")
    }

    /// A miss, then the closed jaws slid from one side of the target to the other, never 9 mm from it: opening there
    /// on the target is felt, however far the jaws went while closed.
    func testAfterAMissOpeningOnTheTargetIsFeltWhereverTheClosedJawsWent() {
        XCTAssertTrue(look(across: 0.005), "5 mm to the right")
        XCTAssertFalse(look(across: 0.005, jawsOpen: false), "closed on nothing")
        XCTAssertFalse(look(across: 0.0, jawsOpen: false))
        XCTAssertFalse(look(across: 0.005, jawsOpen: false), "5 mm to the left, 10 mm from where they closed")
        XCTAssertTrue(look(across: 0.005), "opened on the target")
    }

    /// The closed jaws pushed the target 1 cm along the table, never 9 mm from it, and opened: no lift, so on the
    /// target that is a new try, and it is felt. Raised 13 mm, the target counts as lifted.
    func testAfterPushingTheTargetOpeningOnItIsFelt() {
        XCTAssertTrue(look(across: 0.005))
        XCTAssertFalse(look(across: 0.005, jawsOpen: false))
        for step in 0...10 {
            XCTAssertFalse(look(across: 0.005, target: SIMD3(Double(step) / 1000, 0, 0), jawsOpen: false))
        }
        XCTAssertTrue(look(across: 0.005, target: SIMD3(0.01, 0, 0)), "opened on the pushed target")

        XCTAssertFalse(look(across: 0.003, target: SIMD3(0.01, 0, 0), jawsOpen: false))
        XCTAssertFalse(look(across: 0.003, target: SIMD3(0.01, 0, 0.013), holding: true, jawsOpen: false), "lifted")
        XCTAssertFalse(look(across: 0.003, target: SIMD3(0.01, 0, 0), jawsOpen: false), "set down where it was")
        XCTAssertFalse(look(across: 0.003, target: SIMD3(0.01, 0, 0)), "let go of a lifted target")
    }

    /// States that do not say how the jaws are still show the target rising: a lift seen in them counts.
    func testALiftSeenWithoutTheJawsLabelStillCounts() {
        XCTAssertTrue(look(across: 0.005))
        XCTAssertFalse(look(across: 0.005, jawsOpen: false))
        XCTAssertFalse(look(across: 0.005, target: SIMD3(0, 0, 0.02), holding: true, jawsOpen: nil), "lifted, no label")
        XCTAssertFalse(look(across: 0.005, jawsOpen: nil), "set down, no label")
        XCTAssertFalse(look(across: 0.005), "let go of a lifted target")
    }

    func testASceneResetOrANewTargetArmsItAgain() {
        XCTAssertTrue(look(across: 0.001))
        cue.rearm()
        XCTAssertTrue(look(across: 0.001))
        XCTAssertFalse(look(across: nil))
        XCTAssertTrue(look(across: 0.001), "a target reported after none")
    }

    /// A pick-and-place as the script does it, with a miss first: once per approach to the target. Letting go over the
    /// goal leaves the open jaws on the object, which carried there is no new approach.
    func testOncePerApproachInAScriptedPickAndPlace() {
        var plays: [String: Int] = [:]
        var played = 0
        func counted(
            across: Double?, height: Double = 0, target: SIMD3<Double> = .zero, approximate: Bool = false,
            holding: Bool = false, jawsOpen: Bool = true
        ) {
            let felt = look(
                across: across, height: height, target: target, approximate: approximate, holding: holding,
                jawsOpen: jawsOpen
            )
            if felt { played += 1 }
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
        let goal = SIMD3(0.12, 0.05, 0.002)
        count("the grasp, lift and carry") {
            for _ in 0..<5 { counted(across: 0.0, jawsOpen: false) }
            for step in 0...30 {
                counted(
                    across: 0.0005, target: goal * Double(step) / 30 + SIMD3(0, 0, 0.03), holding: true, jawsOpen: false
                )
            }
            for _ in 0..<5 { counted(across: 0.0005, target: goal, holding: true, jawsOpen: false) }
        }
        count("let go over the goal") {
            counted(across: 0.0005, height: 0.002, target: goal, jawsOpen: false)
            for _ in 0..<5 { counted(across: 0.0005, height: 0.002, target: goal) }
        }
        count("lift away") {
            for step in 0...30 { counted(across: 0.0005, height: 0.002 + Double(step) / 1000, target: goal) }
        }

        XCTAssertEqual(plays["after the reset"], 0)
        XCTAssertEqual(plays["open far away"], 0)
        XCTAssertEqual(plays["first approach, from above, landing with a wobble"], 1)
        XCTAssertEqual(plays["the miss: closed on nothing"], 0)
        XCTAssertEqual(plays["opened again on the target"], 1)
        XCTAssertEqual(plays["backed off 2 cm and came back"], 1)
        XCTAssertEqual(plays["the grasp, lift and carry"], 0)
        XCTAssertEqual(plays["let go over the goal"], 0)
        XCTAssertEqual(plays["lift away"], 0)
    }
}
