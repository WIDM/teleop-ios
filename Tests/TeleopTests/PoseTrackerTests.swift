import simd
import XCTest
@testable import Teleop

/// A camera session that records what the tracker asks of it, in one list with what the tracker reports, so the order
/// of the two shows. Running it moves the test's clock on, as a real run takes time.
private final class FakeCameraSession: CameraSession {
    var events: [String] = []
    var clock = 100.0

    func runResettingTracking() {
        events.append("run with tracking reset")
        clock += 0.25
    }

    func pause() { events.append("pause") }
}

/// The tracker through its seam: what it asks of the camera session for each change of what the screen wants, and what
/// it reports of each run, interruption and frame. ARKit does not run in the iPhone simulator, so the session is a
/// stand-in and the frames are the tracker's own entry points that ARKit's callbacks call.
final class PoseTrackerTests: XCTestCase {
    private var session: FakeCameraSession!
    private var supported = true
    private var granted = true
    private var tracker: PoseTracker!
    private var runs: [TimeInterval] = []
    private var interruptions: [Bool] = []
    private var frames: [(pose: simd_float4x4?, stamp: TimeInterval)] = []

    override func setUp() {
        super.setUp()
        let session = FakeCameraSession()
        self.session = session
        supported = true
        granted = true
        runs = []
        interruptions = []
        frames = []
        tracker = PoseTracker(
            session: session, isSupported: { [unowned self] in self.supported },
            cameraGranted: { [unowned self] in self.granted }, clock: { session.clock })
        tracker.onRun = { [unowned self] in
            self.runs.append($0)
            session.events.append("reported a run")
        }
        tracker.onInterruption = { [unowned self] in self.interruptions.append($0) }
        tracker.onFrame = { [unowned self] in self.frames.append(($0, $1)) }
    }

    private let pose = simd_float4x4(simd_quatf(angle: 0.4, axis: SIMD3(0, 1, 0)))

    func testTheFirstActivationRunsWithTrackingResetAndReportsTheRunWithTheTimeBeforeIt() {
        tracker.setActive(true)
        XCTAssertEqual(session.events, ["run with tracking reset", "reported a run"])
        XCTAssertEqual(runs, [100], "the uptime read just before the run, not after it")
    }

    func testActivatingAgainDoesNothing() {
        tracker.setActive(true)
        tracker.setActive(true)
        XCTAssertEqual(session.events, ["run with tracking reset", "reported a run"])
        XCTAssertEqual(runs.count, 1)
    }

    func testDeactivatingPausesReportsNothingAndForgetsThePose() {
        tracker.setActive(true)
        tracker.frameArrived(pose, tracked: true, stampedAt: 101)
        XCTAssertEqual(tracker.current, pose)
        tracker.setActive(false)
        XCTAssertEqual(session.events, ["run with tracking reset", "reported a run", "pause"])
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(interruptions, [])
        XCTAssertNil(tracker.current)
        tracker.setActive(false)
        XCTAssertEqual(session.events.count, 3, "a second deactivation asks nothing more")
    }

    func testActivatingAfterAPauseRunsAndReportsAgain() {
        tracker.setActive(true)
        tracker.setActive(false)
        session.clock = 200
        tracker.setActive(true)
        XCTAssertEqual(
            session.events,
            ["run with tracking reset", "reported a run", "pause", "run with tracking reset", "reported a run"])
        XCTAssertEqual(runs, [100, 200])
    }

    func testWithoutWorldTrackingOrTheCameraNothingRuns() {
        supported = false
        tracker.setActive(true)
        supported = true
        granted = false
        tracker.setActive(true)
        XCTAssertEqual(session.events, [])
        XCTAssertEqual(runs, [])
        // Access granted later: the next activation runs.
        granted = true
        tracker.setActive(true)
        XCTAssertEqual(session.events, ["run with tracking reset", "reported a run"])
    }

    func testAnInterruptionIsReportedAndForgetsThePose() {
        tracker.setActive(true)
        tracker.frameArrived(pose, tracked: true, stampedAt: 101)
        tracker.interrupted()
        XCTAssertEqual(interruptions, [true])
        XCTAssertNil(tracker.current)
    }

    func testTheEndOfAnInterruptionIsReported() {
        tracker.setActive(true)
        tracker.interrupted()
        tracker.interruptionEnded()
        XCTAssertEqual(interruptions, [true, false])
        XCTAssertEqual(runs.count, 1, "the session resumes by itself; the tracker runs nothing")
    }

    func testEachFrameIsReportedWithItsStampAndAPoseOnlyWhileTracked() {
        tracker.setActive(true)
        tracker.frameArrived(pose, tracked: true, stampedAt: 101.5)
        tracker.frameArrived(pose, tracked: false, stampedAt: 101.6)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames.first?.pose, pose)
        XCTAssertEqual(frames.first?.stamp, 101.5)
        XCTAssertNil(frames.last?.pose ?? nil)
        XCTAssertEqual(frames.last?.stamp, 101.6)
        XCTAssertNil(tracker.current, "a frame without normal tracking leaves no pose")
    }
}
