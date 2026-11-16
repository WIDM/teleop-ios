import XCTest
@testable import TeleopCore

/// The owner's phone, the morning of 2026-11-13: every touch on the STOP band was logged. Nine of eleven were the
/// system's swipe home, which begins in the bottom safe area (the lowest 34 pt, under the home indicator) and goes up
/// the glass. The operating screen defers that gesture, so the first swipe stays in the app and comes to the input
/// rules. Nothing may come of it. A press on the band itself still stops the robot at touch-down.
final class HomeSwipeTests: XCTestCase {
    typealias Rig = ArbiterRig

    /// One raw sample as the measuring build printed it: phase, x, y, `majorRadius`, milliseconds from touch-down.
    typealias Raw = (phase: TouchSample.Phase, x: Double, y: Double, radius: Double, ms: Double)

    private static let b = TouchSample.Phase.began, m = TouchSample.Phase.moved
    private static let e = TouchSample.Phase.ended, c = TouchSample.Phase.cancelled

    /// The nine swipes, sample by sample, as a measuring build on his phone logged them (five in scheme B, four in
    /// scheme A). A swipe that ends `cancelled` is the one that left the app.
    static let morningSwipes: [[Raw]] = [
        // began y 854, 30.0 mm up in 0.14 s
        [
            (b, 164, 854, 36.42, 0), (m, 167, 851, 48.56, 25), (m, 169, 841, 48.56, 46), (m, 171, 831, 48.56, 58),
            (m, 172, 824, 48.56, 67), (m, 173, 812, 48.56, 79), (m, 173, 789, 48.56, 96), (m, 173, 754, 48.56, 113),
            (m, 167, 695, 48.56, 129), (m, 161, 675, 48.56, 133), (e, 159, 673, 0, 138),
        ],
        // began y 857, 21.0 mm up in 0.12 s
        [
            (b, 146, 857, 36.42, 0), (m, 148, 856, 48.56, 21), (m, 151, 842, 48.56, 42), (m, 152, 834, 48.56, 50),
            (m, 153, 826, 48.56, 59), (m, 155, 808, 48.56, 75), (m, 155, 784, 48.56, 92), (m, 155, 753, 60.69, 109),
            (m, 155, 732, 60.69, 117), (e, 153, 730, 0, 121),
        ],
        // began y 858, 26.2 mm up in 0.68 s, resting in the control surface for 0.2 s on the way
        [
            (b, 171, 858, 36.42, 0), (m, 174, 849, 36.42, 41), (m, 175, 841, 36.42, 50), (m, 176, 833, 36.42, 58),
            (m, 179, 815, 48.56, 75), (m, 182, 797, 48.56, 91), (m, 183, 782, 48.56, 108), (m, 184, 769, 48.56, 125),
            (m, 184, 759, 48.56, 141), (m, 184, 751, 48.56, 158), (m, 184, 745, 48.56, 175), (m, 184, 741, 48.56, 191),
            (m, 184, 739, 48.56, 208), (m, 184, 738, 48.56, 221), (m, 184, 737, 48.56, 237), (m, 184, 737, 48.56, 462),
            (m, 184, 735, 48.56, 483), (m, 184, 733, 48.56, 500), (m, 184, 731, 48.56, 516), (m, 184, 727, 48.56, 533),
            (m, 184, 723, 48.56, 550), (m, 184, 719, 48.56, 566), (m, 183, 715, 48.56, 583), (m, 183, 710, 48.56, 600),
            (m, 182, 707, 48.56, 616), (m, 182, 703, 48.56, 633), (m, 180, 701, 48.56, 650), (m, 178, 700, 48.56, 666),
            (m, 176, 700, 48.56, 675), (e, 174, 700, 0, 679),
        ],
        // began y 856, 35.6 mm up in 0.66 s
        [
            (b, 150, 856, 36.42, 0), (m, 152, 854, 36.42, 20), (m, 155, 845, 36.42, 37), (m, 157, 835, 48.56, 50),
            (m, 157, 831, 48.56, 54), (m, 160, 818, 48.56, 70), (m, 163, 806, 48.56, 87), (m, 164, 793, 48.56, 104),
            (m, 166, 781, 48.56, 120), (m, 166, 772, 48.56, 137), (m, 166, 765, 48.56, 154), (m, 166, 760, 48.56, 170),
            (m, 166, 757, 48.56, 187), (m, 166, 755, 48.56, 204), (m, 166, 753, 48.56, 220), (m, 166, 750, 48.56, 237),
            (m, 166, 747, 48.56, 254), (m, 166, 745, 48.56, 270), (m, 166, 743, 48.56, 287), (m, 166, 741, 48.56, 304),
            (m, 166, 739, 48.56, 320), (m, 166, 738, 48.56, 337), (m, 166, 735, 48.56, 354), (m, 166, 733, 48.56, 370),
            (m, 166, 731, 48.56, 387), (m, 166, 728, 48.56, 404), (m, 166, 726, 48.56, 420), (m, 166, 724, 48.56, 437),
            (m, 166, 722, 48.56, 454), (m, 166, 720, 48.56, 470), (m, 166, 719, 48.56, 487), (m, 166, 717, 48.56, 504),
            (m, 166, 715, 48.56, 520), (m, 165, 712, 48.56, 537), (m, 165, 710, 48.56, 554), (m, 164, 706, 48.56, 570),
            (m, 162, 701, 48.56, 587), (m, 159, 693, 48.56, 604), (m, 156, 684, 48.56, 620), (m, 152, 672, 48.56, 637),
            (m, 144, 652, 48.56, 654), (m, 139, 643, 48.56, 658), (e, 137, 641, 0, 662),
        ],
        // began y 854, 10.3 mm up in 0.10 s
        [
            (b, 171, 854, 36.42, 0), (m, 172, 850, 36.42, 20), (m, 172, 841, 48.56, 37), (m, 172, 828, 48.56, 54),
            (m, 172, 813, 48.56, 70), (m, 173, 796, 48.56, 87), (m, 173, 792, 48.56, 91), (c, 173, 792, 48.56, 103),
        ],
        // began y 846, 33.1 mm up in 0.14 s
        [
            (b, 213, 846, 36.42, 0), (m, 215, 832, 48.56, 54), (m, 216, 819, 48.56, 66), (m, 217, 812, 48.56, 70),
            (m, 222, 776, 48.56, 87), (m, 233, 729, 48.56, 104), (m, 249, 680, 48.56, 120), (m, 262, 647, 36.42, 133),
            (e, 264, 646, 0, 137),
        ],
        // began y 862, 38.2 mm up in 0.12 s
        [
            (b, 150, 862, 36.42, 0), (m, 162, 854, 36.42, 16), (m, 168, 844, 36.42, 25), (m, 174, 832, 36.42, 33),
            (m, 186, 806, 48.56, 50), (m, 199, 770, 48.56, 66), (m, 213, 729, 48.56, 83), (m, 230, 683, 48.56, 100),
            (m, 252, 633, 48.56, 116), (e, 254, 631, 0, 121),
        ],
        // began y 846, 44.7 mm up in 0.15 s
        [
            (b, 211, 846, 36.42, 0), (m, 215, 840, 36.42, 8), (m, 215, 837, 36.42, 25), (m, 212, 833, 36.42, 41),
            (m, 209, 821, 36.42, 62), (m, 209, 797, 48.56, 79), (m, 217, 754, 48.56, 95), (m, 237, 700, 48.56, 112),
            (m, 269, 637, 48.56, 129), (m, 296, 590, 48.56, 141), (e, 305, 576, 0, 145),
        ],
        // began y 858, 21.4 mm up in 0.09 s
        [
            (b, 211, 858, 36.42, 0), (m, 215, 847, 36.42, 21), (m, 216, 843, 36.42, 25), (m, 219, 830, 36.42, 38),
            (m, 222, 804, 48.56, 54), (m, 228, 765, 48.56, 71), (m, 239, 729, 48.56, 84), (c, 239, 729, 48.56, 93),
        ],
    ]

    /// His iPhone 17: 460 pixels per inch at 3 pixels per point.
    static let phonePointsPerMm = 460.0 / 3 / 25.4

    /// Feeds one touch to the rig, sample by sample, with the 30 Hz tick the app sends in between, and 0.3 s of
    /// ticks after it. Returns every command that came of it.
    private func replay(_ samples: [Raw], id: Int, on rig: inout Rig) -> [InputCommand] {
        var timeline: [(ms: Double, event: InputEvent)] = samples.map {
            ($0.ms, .touch(TouchSample(id: id, phase: $0.phase, x: $0.x, y: $0.y, majorRadius: $0.radius)))
        }
        let end = samples.last!.ms + 300
        for tick in stride(from: 1000.0 / 30, through: end, by: 1000.0 / 30) { timeline.append((tick, .tick)) }
        timeline.sort { $0.ms < $1.ms }
        let start = rig.time
        var commands: [InputCommand] = []
        for (ms, event) in timeline {
            commands += rig.send(event, after: start + ms / 1000 - rig.time)
        }
        return commands
    }

    /// A straight swipe up the glass from `y`, sampled at 120 Hz, as the phone reports one.
    private func swipe(fromY y: Double, mm: Double, seconds: Double, x: Double = 180) -> [Raw] {
        let steps = Int((seconds * 120).rounded())
        var samples: [Raw] = [(Self.b, x, y, 36.42, 0)]
        for step in 1...steps {
            let up = mm * Self.phonePointsPerMm * Double(step) / Double(steps)
            samples.append((Self.m, x, y - up, 48.56, seconds * 1000 * Double(step) / Double(steps)))
        }
        samples.append((Self.e, x, y - mm * Self.phonePointsPerMm, 0, seconds * 1000 + 4))
        return samples
    }

    // MARK: Part A: his log, through the arbiter

    func testEachSwipeHomeInTheMorningLogDoesNothing() {
        for scheme in [InputScheme.screenTurns, .keyTurns] {
            for connected in [true, false] {
                for (index, samples) in Self.morningSwipes.enumerated() {
                    var rig = Rig(scheme)
                    rig.facts.connectionUp = connected
                    let commands = replay(samples, id: index + 1, on: &rig)
                    XCTAssertEqual(
                        commands, [], "swipe \(index + 1) from y \(samples[0].y), \(scheme), connected \(connected)")
                    XCTAssertTrue(rig.arbiter.held.isEmpty)
                }
            }
        }
    }

    /// The swipes the log describes: from y = 846, 854 and 862, 21 to 45 mm up in 0.09 to 0.15 s, and a slow one,
    /// 30 mm up in 0.67 s.
    func testASwipeHomeFromAnywhereInTheStripDoesNothing() {
        var swipes: [[Raw]] = []
        for y in [846.0, 854, 862] {
            for mm in [21.0, 45] {
                for seconds in [0.09, 0.15] { swipes.append(swipe(fromY: y, mm: mm, seconds: seconds)) }
            }
            swipes.append(swipe(fromY: y, mm: 30, seconds: 0.67))
        }
        for scheme in [InputScheme.screenTurns, .keyTurns] {
            for hand in [Hand.right, .left] {
                for (index, samples) in swipes.enumerated() {
                    var rig = Rig(scheme, hand: hand)
                    XCTAssertEqual(
                        replay(samples, id: index + 1, on: &rig), [],
                        "\(scheme) \(hand): from y \(samples[0].y) to y \(samples[samples.count - 2].y)")
                }
            }
        }
    }

    func testASwipeHomeLeavesAHoldAlone() {
        var rig = Rig(.screenTurns)
        XCTAssertEqual(rig.press(.upper), [.startTranslation])
        XCTAssertEqual(replay(Self.morningSwipes[6], id: 1, on: &rig), [])
        XCTAssertEqual(rig.arbiter.engagedHold, .translation)
        XCTAssertEqual(rig.release(.upper), [.stopTranslation])

        // Scheme B, the thumb closing on the near half: the other thumb's swipe neither stops nor kills it.
        var b = Rig(.keyTurns)
        b.touchDown(1, at: Rig.rightHalf)
        XCTAssertEqual(b.wait(0.2), [.startGripper(.closed)])
        XCTAssertEqual(replay(Self.morningSwipes[1], id: 2, on: &b), [])
        XCTAssertEqual(b.phase(.touch(1)), .engaged(.gripper(.closed)))
        XCTAssertEqual(b.lift(1), [.stopGripper])
    }

    /// A finger resting on the strip is not the one thumb the control surface tracks.
    func testATouchInTheStripIsNotTheTrackedThumb() {
        var rig = Rig(.screenTurns)
        XCTAssertEqual(rig.touchDown(1, at: SIMD2(201, 858)), [])
        XCTAssertFalse(rig.arbiter.isHoldingAnInput)
        rig.touchDown(2, at: Rig.middle, after: 0.05)
        XCTAssertEqual(rig.slide(2, mm: 10, degrees: 90), [.startGripper(.open)])
        XCTAssertEqual(rig.lift(1), [])
        XCTAssertEqual(rig.lift(2), [.stopGripper])
    }

    // MARK: The band itself

    /// Every press that begins on the band stops at touch-down: its top and bottom rows, both side edges, a fingertip,
    /// a radius of 0 and a palm, with a key held.
    func testAPressOnTheBandStillStopsAtTouchDown() {
        var id = 0
        for scheme in [InputScheme.screenTurns, .keyTurns] {
            for y in [768.0, 804, 839.99] {
                for x in [0.0, 6, 201, 395, 401.99] {
                    for radius in [0.0, 24, 48.56, 130] {
                        var rig = Rig(scheme)
                        rig.press(.upper)
                        id += 1
                        XCTAssertEqual(
                            rig.touchDown(id, at: SIMD2(x, y), radius: radius, after: 0.2), [.emergencyStop],
                            "\(scheme) at (\(x), \(y)) radius \(radius)")
                    }
                }
            }
        }
    }

    /// The band ends where the bottom safe area begins, 34 pt above the bottom of the glass.
    func testTheBandEndsWhereTheStripBegins() {
        var rig = Rig(.keyTurns)
        XCTAssertEqual(rig.touchDown(1, at: SIMD2(201, 839.99)), [.emergencyStop])
        XCTAssertEqual(rig.touchDown(2, at: SIMD2(201, 840)), [])
        XCTAssertEqual(rig.touchDown(3, at: SIMD2(201, 873.99)), [])
    }

    /// The two taps on the band in the log, a deliberate one and a slip beside scheme B's corner, still stop.
    func testTheTwoTapsOnTheBandInTheLogStillStop() {
        let taps: [(x: Double, y: Double, radius: Double)] = [(136, 780, 48.56), (131, 823, 36.42)]
        for (index, tap) in taps.enumerated() {
            var rig = Rig(.keyTurns)
            XCTAssertEqual(rig.touchDown(index + 1, at: SIMD2(tap.x, tap.y), radius: tap.radius), [.emergencyStop])
            XCTAssertEqual(rig.lift(index + 1, after: 0.12), [])
        }
    }
}
