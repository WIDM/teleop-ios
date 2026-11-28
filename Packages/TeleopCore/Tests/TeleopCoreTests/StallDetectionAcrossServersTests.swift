import XCTest

@testable import TeleopCore

/// The stall detector is on for a server that runs a simulation loop and never fires for one that does not
/// (`ServerProfile.stallDetection`): each way it fires today, run with the S4 server's `simulation` and with bench arm
/// B's `none`.
final class StallDetectionAcrossServersTests: XCTestCase {
    /// An input with the time it comes at.
    private typealias Timed = (atMs: Int, input: SimStallDetector.Input)

    private func health(captured: UInt64, ageMs: Int, simStalled: Bool? = nil, loopAgeMs: Double? = nil) -> StateHealth
    {
        StateHealth(
            capturedNs: captured, sentNs: captured + UInt64(ageMs) * 1_000_000, simStalled: simStalled,
            loopAgeMs: loopAgeMs)
    }

    private let base: UInt64 = 1_000_000_000_000

    /// Every way the detector fires, each as the inputs that make it fire and the trigger it names.
    private var scenarios: [(name: String, trigger: SimStallDetector.Trigger, inputs: [Timed])] {
        let step: UInt64 = 200_000_000
        return [
            (
                "the server's own flag", .serverFlag,
                [
                    (200, .state(health(captured: base, ageMs: 5))),
                    (400, .state(health(captured: base + step, ageMs: 5, simStalled: true))),
                ]
            ),
            (
                "a refusal that says sim_stalled", .serverRefusal,
                [(200, .refused(request: "pose_start", reason: "sim_stalled"))]
            ),
            (
                "states that grow older without a new write", .frozenTime,
                (0..<3).map { index in
                    (200 * (index + 1), .state(health(captured: base, ageMs: 2100 + 200 * index)))
                }
            ),
            (
                "moves refused busy with no stop answered", .busy,
                [
                    (200, .state(health(captured: base, ageMs: 5))),
                    (400, .refused(request: "pose_start", reason: "busy")),
                    (400 + SimStallDetector.busyMs + 1, .tick),
                ]
            ),
            (
                "a stop nobody answers", .stopUnanswered,
                [
                    (200, .state(health(captured: base, ageMs: 5))), (300, .stopSent(start: 1)),
                    (300 + SimStallDetector.stopAnswerMs, .tick),
                ]
            ),
        ]
    }

    private func run(_ inputs: [Timed], detection: StallDetection) -> (SimStallDetector, changes: Int) {
        var detector = SimStallDetector(detection: detection)
        var changes = 0
        for (atMs, input) in inputs where detector.observe(input, at: atMs) { changes += 1 }
        return (detector, changes)
    }

    func testEachWayTheSimulationDetectorFiresItFires() {
        for scenario in scenarios {
            let (detector, changes) = run(scenario.inputs, detection: .simulation)
            XCTAssertTrue(detector.stalled, scenario.name)
            XCTAssertEqual(detector.trigger, scenario.trigger, scenario.name)
            XCTAssertEqual(changes, 1, scenario.name)
        }
    }

    func testWithNoDetectionItNeverFiresOnTheInputsThatMakeItFire() {
        for scenario in scenarios {
            let (detector, changes) = run(scenario.inputs, detection: .none)
            XCTAssertFalse(detector.stalled, scenario.name)
            XCTAssertEqual(detector.level, .running, scenario.name)
            XCTAssertNil(detector.trigger, scenario.name)
            XCTAssertEqual(changes, 0, scenario.name)
        }
    }

    /// Paused for long enough the simulator counts as not responding; with no detection it never gets that far, however
    /// long the signs go on.
    func testWithNoDetectionNotRespondingIsNeverReached() {
        let long: [Timed] = [
            (200, .state(health(captured: base, ageMs: 5, simStalled: true, loopAgeMs: 20_000))),
            (200 + SimStallDetector.notRespondingMs + 1, .tick),
        ]
        XCTAssertEqual(run(long, detection: .simulation).0.level, .notResponding)
        XCTAssertEqual(run(long, detection: .none).0.level, .running)
    }

    func testTheProfilesChooseTheirDetection() {
        XCTAssertEqual(TestServer.so101.stallDetection, .simulation)
        XCTAssertEqual(TestServer.benchB.stallDetection, .none)
        for (name, server) in TestServer.all {
            let detector = SimStallDetector(detection: server.stallDetection)
            XCTAssertEqual(detector.detection, server.stallDetection, name)
            XCTAssertFalse(detector.stalled, name)
        }
    }
}
