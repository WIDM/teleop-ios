import XCTest
@testable import TeleopCore

/// The lowest rule against the operator's session of 2026-11-20, with the simulator running about 12 passes a second,
/// and against arms coming down at the speeds slower and faster simulators give. "Can't go lower." is told only once
/// the arm has stopped coming down, however slowly it comes down.
final class FeedbackMonitorLowestReplayTests: XCTestCase {
    /// One state of a recorded hold: when it arrived after the press, the pinch point's height and the gripper link's
    /// height, robot base frame, metres.
    private typealias Row = (ms: Int, pinchZ: Double, linkZ: Double)

    /// One recorded down hold on the precision panel (tool point, coordinated height, fine speed): when it was
    /// pressed after the first hold's press, the pinch point and gripper link across the table, and its states.
    private struct RecordedHold {
        let pressMs: Int
        let pinchXY: SIMD2<Double>
        let linkXY: SIMD2<Double>
        let rows: [Row]
    }

    /// The fine speed: the button's target goes down 10 mm a second from the press.
    private static let fineSpeed = 0.01

    /// 10:54:27.122 to 10:54:35.430. The recorded cue came at 7437 ms (10:54:34.579), with the height 1.47 mm lower
    /// than a second before. From 7018 ms on the height moves 0.11 mm at most.
    private static let holdA = RecordedHold(
        pressMs: 0, pinchXY: SIMD2(0.0138, -0.2086), linkXY: SIMD2(0.008, -0.1434),
        rows: [
            (64, 0.09702, 0.16638), (268, 0.09673, 0.16604), (475, 0.09648, 0.1658), (679, 0.09597, 0.16531),
            (882, 0.09519, 0.16454), (1086, 0.09467, 0.16402), (1295, 0.09415, 0.1635), (1508, 0.09362, 0.16298),
            (1710, 0.09284, 0.1622), (1912, 0.09207, 0.16142), (2115, 0.09155, 0.16091), (2320, 0.09104, 0.16039),
            (2524, 0.09027, 0.15962), (2728, 0.0895, 0.15886), (2931, 0.089, 0.15835), (3134, 0.08824, 0.15759),
            (3337, 0.08748, 0.15683), (3544, 0.08723, 0.15658), (3746, 0.08649, 0.15584), (3949, 0.08599, 0.15534),
            (4154, 0.08525, 0.1546), (4357, 0.08452, 0.15386), (4560, 0.08403, 0.15338), (4765, 0.08355, 0.15289),
            (4971, 0.08307, 0.15241), (5175, 0.08235, 0.15169), (5378, 0.08164, 0.15098), (5581, 0.08094, 0.15028),
            (5784, 0.08047, 0.14981), (5990, 0.08001, 0.14934), (6202, 0.07955, 0.14888), (6405, 0.07886, 0.1482),
            (6609, 0.07818, 0.14752), (6813, 0.07774, 0.14707), (7018, 0.07745, 0.14674), (7235, 0.07734, 0.14662),
            (7437, 0.07739, 0.14664), (7651, 0.07739, 0.14666), (7855, 0.07739, 0.14666), (8060, 0.07738, 0.14665),
            (8265, 0.07739, 0.14665),
        ])

    /// 10:54:51.107 to 10:54:58.024. The recorded cue came at 6162 ms (10:54:57.282), 1.97 mm lower than a second
    /// before; the arm went on coming down until the release.
    private static let holdB = RecordedHold(
        pressMs: 23985, pinchXY: SIMD2(-0.0014, -0.21), linkXY: SIMD2(-0.0025, -0.1473),
        rows: [
            (33, 0.07536, 0.14718), (237, 0.07519, 0.14695), (445, 0.07471, 0.14649), (648, 0.0742, 0.146),
            (851, 0.07369, 0.14549), (1054, 0.07318, 0.14498), (1257, 0.07241, 0.14422), (1459, 0.07166, 0.14347),
            (1662, 0.07117, 0.14297), (1867, 0.07068, 0.14248), (2070, 0.07019, 0.14199), (2276, 0.06947, 0.14127),
            (2484, 0.06924, 0.14103), (2687, 0.06876, 0.14056), (2891, 0.06807, 0.13986), (3097, 0.06739, 0.13918),
            (3307, 0.06716, 0.13895), (3510, 0.06671, 0.1385), (3713, 0.06605, 0.13784), (3918, 0.06541, 0.13719),
            (4124, 0.06498, 0.13677), (4327, 0.06415, 0.13593), (4530, 0.06354, 0.13532), (4733, 0.06295, 0.13472),
            (4937, 0.06236, 0.13414), (5140, 0.0618, 0.13357), (5342, 0.06161, 0.13338), (5553, 0.06124, 0.13301),
            (5757, 0.0607, 0.13247), (5960, 0.06017, 0.13194), (6162, 0.05983, 0.13159), (6365, 0.05932, 0.13108),
            (6570, 0.059, 0.13075), (6772, 0.05867, 0.13043),
        ])

    /// 10:54:58.364 to 10:55:05.263. The recorded cue came at 2622 ms (10:55:01.000), 1.95 mm lower than a second
    /// before; the arm stopped at 4062 ms and stood there until the release.
    private static let holdC = RecordedHold(
        pressMs: 31242, pinchXY: SIMD2(-0.0015, -0.2105), linkXY: SIMD2(-0.0026, -0.1476),
        rows: [
            (130, 0.05861, 0.1303), (333, 0.05818, 0.12984), (551, 0.05767, 0.12935), (771, 0.05745, 0.12917),
            (974, 0.05704, 0.12874), (1177, 0.05667, 0.12837), (1381, 0.05613, 0.1278), (1587, 0.05579, 0.12749),
            (1803, 0.05544, 0.12714), (2005, 0.05503, 0.12669), (2208, 0.05439, 0.12609), (2412, 0.05404, 0.12573),
            (2622, 0.05384, 0.12551), (2829, 0.05363, 0.12531), (3036, 0.05329, 0.12494), (3239, 0.0529, 0.12458),
            (3451, 0.05281, 0.12448), (3654, 0.05251, 0.12416), (3857, 0.05238, 0.12397), (4062, 0.05234, 0.1239),
            (4265, 0.05234, 0.12389), (4467, 0.05234, 0.12389), (4670, 0.05234, 0.12389), (4872, 0.05233, 0.12391),
            (5076, 0.05234, 0.1239), (5278, 0.05234, 0.12388), (5481, 0.05234, 0.12388), (5694, 0.05234, 0.12388),
            (5899, 0.05234, 0.1239), (6105, 0.05234, 0.12388), (6313, 0.05234, 0.12388), (6516, 0.05234, 0.12388),
            (6718, 0.05234, 0.1239),
        ])

    /// 10:55:07.815 on. The arm does not move at all; the recorded cue came at 979 ms (10:55:08.794 arrival), the
    /// quicker stall back at the lowest height found before.
    private static let holdD = RecordedHold(
        pressMs: 40693, pinchXY: SIMD2(-0.0019, -0.2142), linkXY: SIMD2(-0.0032, -0.152),
        rows: [
            (139, 0.05234, 0.12464), (343, 0.05234, 0.12448), (547, 0.05234, 0.12446), (768, 0.05234, 0.12449),
            (979, 0.05234, 0.12446), (1184, 0.05234, 0.12447), (1390, 0.05234, 0.12446),
        ])

    /// Plays `hold` into `monitor` as the link does: the start, then before each state the coordinated height's
    /// intent (the button's target from the height at the press), then the release. The events, at ms after the press.
    private func play(_ hold: RecordedHold, into monitor: inout FeedbackMonitor) -> [(ms: Int, event: FeedbackEvent)] {
        let start = hold.pressMs
        monitor.startSent(.pose, restart: false, at: start)
        let startZ = hold.rows[0].pinchZ
        var heard: [(ms: Int, event: FeedbackEvent)] = []
        for row in hold.rows {
            let intent = SIMD3(hold.pinchXY.x, hold.pinchXY.y, startZ - Self.fineSpeed * Double(row.ms) / 1000)
            monitor.commanded(intent, point: .tool)
            let state = ServerState(
                activity: .poseTracking, endEffector: SIMD3(hold.linkXY.x, hold.linkXY.y, row.linkZ),
                toolPoint: SIMD3(hold.pinchXY.x, hold.pinchXY.y, row.pinchZ))
            heard += monitor.observe(state, at: start + row.ms).map { (row.ms, $0) }
        }
        monitor.released(.pose)
        return heard
    }

    private func newMonitor() -> FeedbackMonitor {
        var monitor = FeedbackMonitor(limits: GripperLimits(openDeg: 97, emptyDeg: 2), frames: TestFrames.so101)
        monitor.reportsLowest = true
        return monitor
    }

    /// The four recorded cues: the three that came while the arm was still coming down 1.4 to 2.0 mm a second are not
    /// told then. Hold A's arm then stood still (0.35 mm in the second judged) and is told 0.4 s after the recorded
    /// cue; hold C's arm is told once it stood on the table; hold D's arm, which never moved, is told when it was.
    func testTheRecordedSessionIsToldOnlyOnceTheArmHasStopped() {
        var monitor = newMonitor()
        let a = play(Self.holdA, into: &monitor)
        let b = play(Self.holdB, into: &monitor)
        let c = play(Self.holdC, into: &monitor)
        let d = play(Self.holdD, into: &monitor)
        XCTAssertFalse(a.contains { $0.ms <= 7651 }, "hold A while coming down: \(a)")
        XCTAssertEqual(a.map(\.ms), [7855], "\(a)")
        XCTAssertEqual(b.map(\.event), [], "hold B never stopped coming down")
        XCTAssertFalse(c.contains { $0.ms < 4062 }, "hold C while coming down: \(c)")
        XCTAssertEqual(c.map(\.ms), [4467], "\(c)")
        XCTAssertEqual(d.map(\.ms), [979], "the stopped arm, as recorded: \(d)")
        for heard in a + c + d { XCTAssertEqual(heard.event, .limit(.lowest)) }
        XCTAssertEqual(monitor.lowestPinchSeen ?? 0, 0.05234, accuracy: 0.00002, "where the arm stood on the table")
    }

    /// The simulator's pace sets how fast the arm comes down under a fine-speed ask: at about 12 passes a second the
    /// session recorded 1.4 to 2.0 mm a second, so about 0.75 mm at 6 passes and 4.5 mm at 30; 0.6 mm is slower than
    /// any of them. States come every 200 ms (the listening connection) or every 100 ms. Nothing is told while the arm
    /// comes down, and "Can't go lower." comes within 1.2 s of its stopping.
    func testAnArmComingDownIsNotToldAtAnySimulatorPace() {
        for metersPerSecond in [0.0006, 0.00075, 0.0015, 0.002, 0.0045] {
            for every in [100, 200] {
                var monitor = newMonitor()
                monitor.startSent(.pose, restart: false, at: 0)
                let stopMs = 6000
                var heard: [(ms: Int, event: FeedbackEvent)] = []
                for t in stride(from: every, through: 9000, by: every) {
                    let z = 0.09 - metersPerSecond * Double(min(t, stopMs)) / 1000
                    monitor.commanded(SIMD3(0.01, -0.2, 0.09 - Self.fineSpeed * Double(t) / 1000), point: .tool)
                    let state = ServerState(
                        activity: .poseTracking, endEffector: SIMD3(0, -0.14, z + 0.07), toolPoint: SIMD3(0.01, -0.2, z)
                    )
                    heard += monitor.observe(state, at: t).map { (t, $0) }
                }
                let label = "\(metersPerSecond * 1000) mm/s, every \(every) ms: \(heard)"
                XCTAssertFalse(heard.contains { $0.ms <= stopMs }, label)
                XCTAssertEqual(heard.map(\.event), [.limit(.lowest)], label)
                XCTAssertLessThanOrEqual(heard.first?.ms ?? .max, stopMs + 1200, label)
            }
        }
    }
}
