import TeleopCore
import XCTest

final class ToolPointFeedbackTests: XCTestCase {
    private let origin = SIMD3(0.0, -0.14, 0.16)
    private let tool = SIMD3(0.01, -0.17, 0.07)

    private func monitor(aids: Bool) -> FeedbackMonitor {
        var monitor = FeedbackMonitor(limits: GripperLimits(openDeg: 97, emptyDeg: 2))
        monitor.reportsLowest = aids
        if aids { monitor.blockedWorkspace = (SIMD3(-0.1, -0.3, 0.12), SIMD3(0.1, 0, 0.3)) }
        monitor.startSent(.pose, restart: false, at: 0)
        monitor.commanded(tool + SIMD3(0.03, 0, 0), point: .tool)
        return monitor
    }

    func testFrozenToolIsBlockedEvenWhenLinkOriginMoves() {
        for aids in [false, true] {
            var monitor = monitor(aids: aids)
            var events: [FeedbackEvent] = []
            for time in stride(from: 0, through: 1400, by: 200) {
                events += monitor.observe(
                    ServerState(
                        activity: .poseTracking, endEffector: origin + SIMD3(Double(time) * 0.00001, 0, 0),
                        toolPoint: tool),
                    at: time)
            }
            XCTAssertEqual(events, [.limit(.blocked)], "aids = \(aids)")
        }
    }

    func testToolProgressIsNotBlockedEvenWhenLinkOriginStandsStill() {
        for aids in [false, true] {
            var monitor = monitor(aids: aids)
            var events: [FeedbackEvent] = []
            for time in stride(from: 0, through: 1400, by: 200) {
                events += monitor.observe(
                    ServerState(
                        activity: .poseTracking, endEffector: origin,
                        toolPoint: tool + SIMD3(Double(time) * 0.00001, 0, 0)),
                    at: time)
            }
            XCTAssertTrue(events.isEmpty, "aids = \(aids), \(events)")
        }
    }

    func testMissingToolCannotFallBackToOriginOrBridgeAnUnmeasuredWindow() {
        var monitor = monitor(aids: true)
        var events: [FeedbackEvent] = []
        for time in stride(from: 0, through: 2000, by: 200) {
            events += monitor.observe(
                ServerState(
                    activity: .poseTracking, endEffector: origin, toolPoint: time < 400 || time >= 1600 ? tool : nil),
                at: time)
        }
        XCTAssertTrue(events.isEmpty)
    }

    func testToolFeedbackRequiresRegularArrivalWithAidsOffToo() {
        var monitor = monitor(aids: false)
        var events: [FeedbackEvent] = []
        for time in [0, 200, 400, 1200, 1200, 1200] {
            events += monitor.observe(
                ServerState(activity: .poseTracking, endEffector: origin, toolPoint: tool), at: time)
        }
        XCTAssertTrue(events.isEmpty)
    }

    func testReleasedOrResyncingToolDoesNotReportBlocked() {
        for released in [false, true] {
            var monitor = monitor(aids: false)
            _ = monitor.observe(ServerState(activity: .poseTracking, endEffector: origin, toolPoint: tool), at: 0)
            if released { monitor.released(.pose) } else { monitor.resyncBegan() }
            var events: [FeedbackEvent] = []
            for time in stride(from: 200, through: 1400, by: 200) {
                events += monitor.observe(
                    ServerState(activity: .poseTracking, endEffector: origin, toolPoint: tool), at: time)
            }
            XCTAssertTrue(events.isEmpty)
        }
    }

    func testOperatorIntentAndMeasuredProgressSurviveShortInternalResyncsButNotRelease() {
        for progresses in [false, true] {
            var monitor = monitor(aids: true)
            var events: [FeedbackEvent] = []
            for time in stride(from: 0, through: 1600, by: 100) {
                if time > 0, time % 500 == 0 {
                    monitor.resyncBegan()
                    events += monitor.observe(
                        ServerState(activity: .ok, endEffector: origin, toolPoint: tool), at: time)
                    monitor.startSent(.pose, restart: true, at: time)
                    monitor.commanded(tool + SIMD3(0.03, 0, 0), point: .tool)
                }
                events += monitor.observe(
                    ServerState(
                        activity: .poseTracking, endEffector: origin,
                        toolPoint: tool + SIMD3(progresses ? Double(time) * 0.000005 : 0, 0, 0)), at: time)
            }
            XCTAssertEqual(events, progresses ? [] : [.limit(.blocked)])
            monitor.released(.pose)
            monitor.startSent(.pose, restart: false, at: 1800)
            monitor.commanded(tool + SIMD3(0.03, 0, 0), point: .tool)
            XCTAssertTrue(
                monitor.observe(ServerState(activity: .poseTracking, endEffector: origin, toolPoint: tool), at: 1800)
                    .isEmpty)
            monitor.released(.pose)
            XCTAssertTrue(
                monitor.observe(ServerState(activity: .poseTracking, endEffector: origin, toolPoint: tool), at: 3000)
                    .isEmpty)
        }
    }

    func testToolDownwardStallKeepsActualOriginAndPinchHeights() {
        var monitor = monitor(aids: true)
        monitor.commanded(tool - SIMD3(0, 0, 0.02), point: .tool)
        var events: [FeedbackEvent] = []
        for time in stride(from: 0, through: 1400, by: 200) {
            events += monitor.observe(
                ServerState(activity: .poseTracking, endEffector: origin, toolPoint: tool), at: time)
        }
        XCTAssertEqual(events, [.limit(.lowest)])
        XCTAssertEqual(monitor.lowestSeen, origin.z)
        XCTAssertEqual(monitor.lowestPinchSeen, tool.z)
    }

    /// A pinch point that stands still while the command lies 20 mm to the side and alternately 12 and 4 mm lower. The
    /// lowest rule never judges such a window (it needs every state of the second asked at least 5 mm lower), so
    /// "Blocked." is not left to it and comes after the second, as without the lowest rule.
    func testASidewaysStallWithAnUnevenAskForLowerIsStillBlocked() {
        var monitor = monitor(aids: true)
        var events: [FeedbackEvent] = []
        var toldAt: Int?
        for (index, time) in stride(from: 0, through: 2000, by: 200).enumerated() {
            let lower = index % 2 == 0 ? 0.012 : 0.004
            monitor.commanded(tool + SIMD3(0.02, 0, -lower), point: .tool)
            let new = monitor.observe(
                ServerState(activity: .poseTracking, endEffector: origin, toolPoint: tool), at: time)
            if !new.isEmpty, toldAt == nil { toldAt = time }
            events += new
        }
        XCTAssertEqual(events, [.limit(.blocked)])
        XCTAssertEqual(toldAt, 1000)
    }
}
