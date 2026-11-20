import XCTest
@testable import TeleopServerModel

/// A simulation loop that stops while the front end keeps answering, as on 2026-11-19: the front end says so instead
/// of `busy` forever, never releases the stop, and a running loop behaves as before.
final class StallRuleTests: XCTestCase {
    private var bench: Bench!
    private var phone: Bench.Client!

    override func setUp() {
        var config = ServerModelConfig.s4Simulator
        config.reportsLoopHealth = true
        bench = Bench(config)
        phone = bench.client()
        bench.wait(0.5)
    }

    /// Past the stall threshold, with no pass since.
    private func stallTheLoop() {
        bench.model.stallLoop()
        bench.wait(bench.config.loopStallSeconds + 0.5)
    }

    func testAStopTheLoopNeverFrozeIsRefusedAsStalledAndStaysLatched() {
        stallTheLoop()
        let estop = phone.send("estop")
        XCTAssertEqual(phone.reason(estop), "ok estop_engaged", "the front end still takes the stop")
        let release = phone.send("estop_reset")
        XCTAssertEqual(phone.reason(release), "rejected sim_stalled")
        XCTAssertEqual(phone.lastState["estop"]?.boolValue, true, "the stop stays latched")
        bench.wait(2)
        XCTAssertEqual(phone.reason(phone.send("estop_reset")), "rejected sim_stalled")
        XCTAssertEqual(phone.lastState["estop"]?.boolValue, true)
    }

    func testAStopTheLoopFrozeIsStillRefusedDuringAStall() {
        _ = phone.send("estop")
        bench.wait(bench.stepTime + 0.001)
        XCTAssertTrue(bench.model.estopFrozen)
        stallTheLoop()
        XCTAssertEqual(phone.reason(phone.send("estop_reset")), "rejected sim_stalled", "a stalled loop holds nothing")
        XCTAssertEqual(phone.lastState["estop"]?.boolValue, true)
    }

    func testARunningLoopStillSaysNotFrozen() {
        let estop = phone.send("estop")
        XCTAssertEqual(phone.reason(estop), "ok estop_engaged")
        XCTAssertEqual(phone.reason(phone.send("estop_reset")), "rejected estop_not_frozen")
        bench.wait(bench.stepTime + 0.001)
        XCTAssertEqual(phone.reason(phone.send("estop_reset")), "ok estop_reset")
    }

    func testAStallWithAStartQueuedLatchesTheStopAndAnswersTheStart() {
        // The loop stops before it takes the queued start, as the 22:07:18 hold was never taken.
        bench.model.stallLoop()
        let hold = phone.poseStart()
        XCTAssertNil(phone.ack(hold))
        bench.wait(0.3)
        XCTAssertEqual(phone.reason(phone.poseStart()), "rejected busy", "short of the threshold, still busy")
        XCTAssertEqual(phone.lastState["estop"]?.boolValue, false)
        bench.wait(bench.config.loopStallSeconds)
        XCTAssertEqual(phone.reason(hold), "rejected sim_stalled", "it never ran, so it is answered")
        XCTAssertEqual(phone.lastState["estop"]?.boolValue, true, "the front end latched the stop itself")
        XCTAssertEqual(phone.reason(phone.poseStart()), "rejected estop_active")
        XCTAssertEqual(phone.reason(phone.send("estop_reset")), "rejected sim_stalled")
        XCTAssertEqual(phone.reason(phone.send("reset_scene")), "rejected sim_stalled")
        XCTAssertEqual(phone.lastState["estop"]?.boolValue, true)
    }

    func testAStartDuringAStallWithNothingQueuedIsToldStalled() {
        stallTheLoop()
        XCTAssertEqual(phone.reason(phone.poseStart()), "rejected sim_stalled")
        XCTAssertEqual(phone.lastState["estop"]?.boolValue, false, "nothing queued, nothing latched")
    }

    func testAResetDuringAStallLeavesTheStopLatched() {
        _ = phone.send("estop")
        bench.wait(bench.stepTime + 0.001)
        stallTheLoop()
        let reset = phone.send("reset_scene")
        XCTAssertEqual(phone.reason(reset), "rejected sim_stalled")
        XCTAssertEqual(phone.lastState["estop"]?.boolValue, true)
        XCTAssertTrue(bench.model.estopFrozen, "the reset changed nothing")
    }

    func testTheStateSaysTheLoopStalled() {
        let running = phone.lastState
        XCTAssertEqual(running["sim_stalled"]?.boolValue, false)
        XCTAssertLessThan(running["loop_age_ms"]?.intValue ?? .max, 200)
        stallTheLoop()
        let stalled = phone.lastState
        XCTAssertEqual(stalled["sim_stalled"]?.boolValue, true)
        XCTAssertGreaterThanOrEqual(stalled["loop_age_ms"]?.intValue ?? 0, 1000)
    }

    /// A server without the heartbeat, which the recordings come from, sends neither field.
    func testAServerWithoutTheHeartbeatSendsNeitherField() {
        let older = Bench()
        let client = older.client()
        older.wait(0.5)
        XCTAssertNil(client.lastState["sim_stalled"])
        XCTAssertNil(client.lastState["loop_age_ms"])
    }
}
