import Foundation
import XCTest

@testable import TeleopCore

/// The jaw rules run once per jaw: the SO-101's hinged jaw read in degrees and bench arm B's parallel jaws read in
/// millimetres (`TestJaw`). Each case is one the SO-101's own tests pin, written in the jaw's own readings: a place
/// along its travel instead of a number, so what holds for B is what holds for the SO-101 with B's readings in it.
final class JawAcrossJawsTests: XCTestCase {
    /// The reading `share` of the way from shut to open.
    private func reading(_ jaw: GripperProfile, at share: Double) -> Double {
        jaw.closedReading + share * (jaw.openReading - jaw.closedReading)
    }

    private func state(_ activity: ServerActivity? = nil, jaw: Double?) -> ServerState {
        ServerState(activity: activity, gripperDeg: jaw)
    }

    private func monitor(_ jaw: GripperProfile) -> FeedbackMonitor {
        FeedbackMonitor(limits: jaw.limits, frames: TestFrames.so101)
    }

    func testBenchBDiffersFromTheSO101InEveryJawNumber() {
        let a = TestJaw.so101, b = TestJaw.benchB
        XCTAssertNotEqual(a.unit, b.unit)
        XCTAssertNotEqual(a.closedReading, b.closedReading + 1, "B's closed reading is not just shifted")
        XCTAssertNotEqual(a.openReading, b.openReading)
        XCTAssertNotEqual(a.validMin, b.validMin)
        XCTAssertNotEqual(a.validMax, b.validMax)
        XCTAssertNotEqual(a.fullyOpenAt, b.fullyOpenAt)
        XCTAssertNotEqual(a.emptyAt, b.emptyAt)
    }

    /// The SO-101's 97 degrees is fully open and 0 shut (OperatingRulesTests, GuideLayoutTests).
    func testTheSO101JawOpensBetweenZeroAndNinetySeven() {
        let jaw = TestJaw.so101
        XCTAssertEqual(jaw.opening(at: 0), 0)
        XCTAssertEqual(jaw.opening(at: 97), 1)
        XCTAssertEqual(jaw.opening(at: 48.5), 0.5)
        XCTAssertEqual(jaw.opening(at: 60), 60.0 / 97.0)
    }

    func testTheOpeningShareIsDrawnBetweenTheJawsOwnTwoReadings() {
        for (name, jaw) in TestJaw.all {
            for share in [0.0, 0.25, 0.5, 0.62, 1.0] {
                XCTAssertEqual(jaw.opening(at: reading(jaw, at: share)), share, accuracy: 1e-12, "\(name) \(share)")
            }
            XCTAssertEqual(jaw.opening(at: reading(jaw, at: -0.2)), 0, "\(name): held to shut")
            XCTAssertEqual(jaw.opening(at: reading(jaw, at: 1.2)), 1, "\(name): held to open")
        }
    }

    /// A jaw whose shut reading is not 0 is drawn from that reading, not from zero.
    func testAShutReadingThatIsNotZeroIsTheZeroOfTheShare() {
        var jaw = TestJaw.benchB
        jaw.closedReading = 5
        jaw.openReading = 45
        XCTAssertEqual(jaw.opening(at: 5), 0)
        XCTAssertEqual(jaw.opening(at: 25), 0.5)
        XCTAssertEqual(jaw.opening(at: 45), 1)
        XCTAssertEqual(jaw.opening(at: 2), 0)
    }

    /// FeedbackMonitorTests.testFullyOpen: part way open is not yet; a little past the threshold while opening is
    /// fully open, once.
    func testFullyOpenIsToldAtTheJawsOwnThreshold() {
        for (name, jaw) in TestJaw.all {
            var monitor = monitor(jaw)
            monitor.startSent(.gripper(.open), restart: false, at: 0)
            XCTAssertEqual(monitor.observe(state(jaw: reading(jaw, at: 0.62)), at: 200), [], name)
            XCTAssertEqual(
                monitor.observe(state(jaw: jaw.fullyOpenAt + 0.005 * (jaw.openReading - jaw.closedReading)), at: 400),
                [.limit(.fullyOpen)], name)
            XCTAssertEqual(monitor.observe(state(jaw: jaw.openReading), at: 600), [], "\(name): once")
        }
    }

    /// Just under the threshold is not fully open.
    func testJustUnderTheThresholdIsNotFullyOpen() {
        for (name, jaw) in TestJaw.all {
            var monitor = monitor(jaw)
            monitor.startSent(.gripper(.open), restart: false, at: 0)
            XCTAssertEqual(monitor.observe(state(jaw: jaw.fullyOpenAt - 0.001), at: 200), [], name)
            XCTAssertEqual(monitor.observe(state(jaw: jaw.fullyOpenAt), at: 400), [.limit(.fullyOpen)], name)
        }
    }

    /// FeedbackMonitorTests.testAnEmptyClose: while the jaws still close contact may come; once the close has ended
    /// with the jaws at or under the empty threshold and no contact, they closed on nothing.
    func testAnEmptyCloseIsToldAtTheJawsOwnThreshold() {
        for (name, jaw) in TestJaw.all {
            var monitor = monitor(jaw)
            monitor.startSent(.gripper(.closed), restart: false, at: 0)
            XCTAssertEqual(monitor.observe(state(.gripperJogging, jaw: reading(jaw, at: 0.31)), at: 200), [], name)
            XCTAssertEqual(monitor.observe(state(.gripperJogging, jaw: jaw.emptyAt - 0.001), at: 400), [], name)
            monitor.released(.gripper(.closed))
            XCTAssertEqual(monitor.observe(state(.ok, jaw: jaw.emptyAt), at: 800), [.limit(.empty)], name)
            XCTAssertEqual(monitor.observe(state(.ok, jaw: jaw.emptyAt), at: 1000), [], "\(name): once")
            XCTAssertFalse(monitor.gripping, name)
        }
    }

    /// A close that ended with the jaws just over the empty threshold held something small, or nothing, but is not
    /// told as empty.
    func testACloseEndingOverTheEmptyThresholdIsNotEmpty() {
        for (name, jaw) in TestJaw.all {
            var monitor = monitor(jaw)
            monitor.startSent(.gripper(.closed), restart: false, at: 0)
            monitor.released(.gripper(.closed))
            XCTAssertEqual(monitor.observe(state(.ok, jaw: jaw.emptyAt + 0.001), at: 200), [], name)
        }
    }

    /// FeedbackMonitorTests.testARecordedGripBelowTheEmptyAngleIsNotEmpty: contact told while closing, the grip
    /// resting under the empty threshold, is a grip and not empty.
    func testAGripRestingUnderTheEmptyThresholdIsNotEmpty() {
        for (name, jaw) in TestJaw.all {
            var monitor = monitor(jaw)
            monitor.startSent(.gripper(.closed), restart: false, at: 0)
            for (atMs, share) in [(200, 0.23), (400, 0.14), (600, 0.07)] {
                XCTAssertEqual(
                    monitor.observe(state(.gripperJogging, jaw: reading(jaw, at: share)), at: atMs), [], name)
            }
            let resting = jaw.emptyAt * 0.8
            XCTAssertEqual(monitor.observe(state(.gripperContact, jaw: resting), at: 1200), [.contact], name)
            monitor.released(.gripper(.closed))
            XCTAssertEqual(monitor.observe(state(.ok, jaw: resting), at: 1600), [], name)
            XCTAssertTrue(monitor.gripping, name)
        }
    }

    /// JawsClosedReminder: without the server's jaws label the reading decides, shut at or under the empty threshold.
    func testTheJawsAreClosedByTheLabelOrByTheEmptyThreshold() {
        for (name, jaw) in TestJaw.all {
            let limits = jaw.limits
            XCTAssertEqual(
                JawsClosedReminder.jawsClosed(nil, degrees: jaw.emptyAt, limits: limits), true, name)
            XCTAssertEqual(
                JawsClosedReminder.jawsClosed(nil, degrees: jaw.emptyAt + 0.001, limits: limits), false, name)
            XCTAssertNil(JawsClosedReminder.jawsClosed(nil, degrees: nil, limits: limits), name)
            XCTAssertEqual(JawsClosedReminder.jawsClosed(.closed, degrees: jaw.openReading, limits: limits), true, name)
        }
    }

    // MARK: Which readings count

    private func payload(jaw: Double?, flex: Double? = nil) -> [String: Any] {
        var payload: [String: Any] = ["estop": false, "gripper": "open"]
        if let jaw { payload["gripper_deg"] = jaw }
        if let flex { payload["wrist_flex_deg"] = flex }
        return payload
    }

    /// ServerStateTests: a reading up to a full turn either way counts for the SO-101, one beyond it does not.
    func testTheSO101AcceptsWhatTheParserAlwaysDid() {
        let range = TestJaw.so101.validReadings
        for accepted in [-360.0, -1, 0, 97, 360] {
            XCTAssertEqual(ServerState(payload: payload(jaw: accepted), jawReadings: range).gripperDeg, accepted)
        }
        for dropped in [-360.5, 361, 1e20, -1e20] {
            XCTAssertNil(ServerState(payload: payload(jaw: dropped), jawReadings: range).gripperDeg, "\(dropped)")
        }
    }

    func testAJawReadingCountsOnlyInsideTheJawsOwnValidReadings() {
        for (name, jaw) in TestJaw.all {
            let range = jaw.validReadings
            for accepted in [range.lowerBound, jaw.closedReading, jaw.openReading, range.upperBound] {
                XCTAssertEqual(
                    ServerState(payload: payload(jaw: accepted), jawReadings: range).gripperDeg, accepted, name)
            }
            for dropped in [range.lowerBound - 0.01, range.upperBound + 0.01] {
                XCTAssertNil(ServerState(payload: payload(jaw: dropped), jawReadings: range).gripperDeg, name)
            }
        }
    }

    /// C6 stays 360 degrees for the wrist joints whatever the jaw's range is: a joint reported in radians or a number
    /// that cannot be an angle is dropped, and the jaw's valid readings do not widen it or narrow it.
    func testTheWristJointsKeepTheirOwnBoundWhateverTheJawAccepts() {
        for range in [TestJaw.so101.validReadings, TestJaw.benchB.validReadings, -1000...1000] {
            let inside = ServerState(payload: payload(jaw: nil, flex: 359), jawReadings: range)
            XCTAssertEqual(inside.wristFlexDeg, 359)
            let outside = ServerState(payload: payload(jaw: nil, flex: 361), jawReadings: range)
            XCTAssertNil(outside.wristFlexDeg, "\(range)")
        }
        let wide = ServerState(payload: payload(jaw: 500, flex: 500), jawReadings: -1000...1000)
        XCTAssertEqual(wide.gripperDeg, 500)
        XCTAssertNil(wide.wristFlexDeg)
    }

    /// The link reads a state with its own jaw's readings: B's link drops a reading its jaw cannot give.
    func testTheLinkReadsStatesWithTheJawsReadings() {
        for (name, jaw) in TestJaw.all {
            let link = TeleopLink(send: { _ in }, now: { 0 }, jawReadings: jaw.validReadings)
            func receive(_ type: String, _ payload: [String: Any]) {
                let message: [String: Any] = ["v": 1, "type": type, "ts": 0, "seq": 0, "payload": payload]
                _ = link.receive(String(data: try! JSONSerialization.data(withJSONObject: message), encoding: .utf8)!)
            }
            link.hello(name: "test")
            receive("welcome", [:])
            receive("state", payload(jaw: jaw.openReading))
            XCTAssertEqual(link.lastState?.gripperDeg, jaw.openReading, name)
            receive("state", payload(jaw: jaw.validMax + 1))
            XCTAssertNil(link.lastState?.gripperDeg, name)
        }
    }

    func testAReadingIsWrittenWithItsUnit() {
        XCTAssertEqual(TestJaw.so101.text(97), "97 deg")
        XCTAssertEqual(TestJaw.benchB.text(39), "39 mm")
        XCTAssertEqual(TestJaw.benchB.text(12.34), "12.3 mm")
    }
}
