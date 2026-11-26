import Foundation
import XCTest
@testable import Teleop

final class ExperimentTimingTests: XCTestCase {
    private final class Capture {
        var messages: [(type: String, payload: [String: Any])] = []
        var nextID = 0

        func events(_ kind: String) -> [[String: Any]] {
            messages.filter { $0.type == "telemetry" && $0.payload["kind"] as? String == kind }.map(\.payload)
        }

        func details(_ kind: String) -> [String: Any] {
            events(kind).last?["details"] as? [String: Any] ?? [:]
        }
    }

    private let ms: UInt64 = 1_000_000

    private func make(ack: Bool = false, at time: UInt64 = 100_000_000) -> (ExperimentTiming, Capture) {
        let capture = Capture()
        let timing = ExperimentTiming(
            clientClockID: "phone-test", now: { time },
            makeID: {
                capture.nextID += 1
                return "event-\(capture.nextID)"
            })
        timing.send = { capture.messages.append(($0, $1)) }
        timing.receive(
            type: "welcome",
            payload: [
                "telemetry_version": 1, "server_clock_id": "server-a", "connection_id": "connection-a",
                "telemetry_acknowledgements": ack,
            ], localMonotonicNs: time)
        return (timing, capture)
    }

    private func synchronize(_ timing: ExperimentTiming, _ capture: Capture) {
        let probe = capture.messages.last { $0.type == "clock_probe" }!.payload
        timing.receive(
            type: "clock_reply",
            payload: [
                "probe_id": probe["probe_id"]!, "client_send_ns": probe["client_send_ns"]!,
                "server_receive_ns": 1300 * ms, "server_send_ns": 1320 * ms, "server_clock_id": "server-a",
            ], localMonotonicNs: 200 * ms)
    }

    private func state(_ timing: ExperimentTiming, at time: UInt64, clock: String = "server-a", id: Any = 7) {
        timing.receive(
            type: "state",
            payload: [
                "timing": [
                    "state_id": id, "captured_monotonic_ns": 1380 * ms,
                    "sent_monotonic_ns": 1390 * ms, "server_clock_id": clock,
                ],
                "study": ["trial_id": "trial-1"],
            ], localMonotonicNs: time)
    }

    func testAsymmetricRoundTripProducesBoundsNotHalfRoundTripClaim() {
        let (timing, capture) = make()
        synchronize(timing, capture)
        XCTAssertEqual(timing.clockBounds?.lowerOffsetNs, 1120 * Int64(ms))
        XCTAssertEqual(timing.clockBounds?.upperOffsetNs, 1200 * Int64(ms))
        XCTAssertTrue(capture.details("clock_bound")["one_way_exact_ms"] is NSNull)
        state(timing, at: 260 * ms)
        let measured = capture.details("state_received")
        XCTAssertEqual(measured["server_assembly_to_send_ms"] as? Double, 10)
        XCTAssertEqual(measured["state_age_lower_ms"] as? Double, 0)
        XCTAssertEqual(measured["state_age_upper_ms"] as? Double ?? -1, 80.16, accuracy: 0.001)
        XCTAssertNil(measured["measurement_error"])
    }

    func testClockDriftDuringTheProbeIsIncludedInTheAgeBound() {
        let (timing, capture) = make(at: 0)
        let probe = capture.messages.last { $0.type == "clock_probe" }!.payload
        timing.receive(
            type: "clock_reply",
            payload: [
                "probe_id": probe["probe_id"]!, "client_send_ns": probe["client_send_ns"]!,
                "server_receive_ns": 0, "server_send_ns": 0, "server_clock_id": "server-a",
            ], localMonotonicNs: 1000 * ms)
        timing.receive(
            type: "state",
            payload: [
                "timing": [
                    "state_id": 1, "captured_monotonic_ns": 0, "sent_monotonic_ns": 0,
                    "server_clock_id": "server-a",
                ]
            ], localMonotonicNs: 1000 * ms)
        XCTAssertGreaterThanOrEqual(capture.details("state_received")["state_age_upper_ms"] as? Double ?? -1, 1001)
    }

    func testExpiredClockDoesNotInventAge() {
        let (timing, capture) = make()
        synchronize(timing, capture)
        state(timing, at: 20_000 * ms)
        XCTAssertEqual(
            capture.details("state_received")["measurement_error"] as? String, "clock_bound_missing_or_expired")
        XCTAssertTrue(capture.details("state_received")["state_age_upper_ms"] is NSNull)
    }

    func testRestartClearsClockAndRejectsDelayedReply() {
        let (timing, capture) = make()
        synchronize(timing, capture)
        let oldProbe = capture.messages.last { $0.type == "clock_probe" }!.payload
        timing.receive(
            type: "welcome",
            payload: [
                "telemetry_version": 1, "server_clock_id": "server-b", "connection_id": "connection-b",
            ], localMonotonicNs: 300 * ms)
        timing.receive(
            type: "clock_reply",
            payload: [
                "probe_id": oldProbe["probe_id"]!, "client_send_ns": oldProbe["client_send_ns"]!,
                "server_receive_ns": 1300 * ms, "server_send_ns": 1320 * ms, "server_clock_id": "server-a",
            ], localMonotonicNs: 350 * ms)
        XCTAssertNil(timing.clockBounds)
        XCTAssertEqual(capture.events("clock_probe_rejected").count, 1)
        state(timing, at: 400 * ms)
        XCTAssertEqual(
            capture.details("state_received")["measurement_error"] as? String, "missing_or_invalid_source_timing")
    }

    func testInvalidNumbersAndMismatchedProbeCannotCalibrate() {
        let (timing, capture) = make()
        let probe = capture.messages.last { $0.type == "clock_probe" }!.payload
        for value: Any in [true, 1300.5, UInt64.max, -1] {
            timing.receive(
                type: "clock_reply",
                payload: [
                    "probe_id": probe["probe_id"]!, "client_send_ns": probe["client_send_ns"]!,
                    "server_receive_ns": value, "server_send_ns": 1320 * ms, "server_clock_id": "server-a",
                ], localMonotonicNs: 200 * ms)
            XCTAssertNil(timing.clockBounds)
        }
        XCTAssertEqual(capture.events("clock_probe_rejected").count, 4)
    }

    func testLongDelayedStateRetainsItsOwnSourceIdentity() {
        let (timing, capture) = make()
        synchronize(timing, capture)
        state(timing, at: 2000 * ms, id: 4)
        let event = capture.events("state_received").last!
        XCTAssertEqual(event["source_state_id"] as? UInt64, 4)
        XCTAssertEqual(event["trial_id"] as? String, "trial-1")
        XCTAssertEqual(event["client_clock_id"] as? String, "phone-test")
        XCTAssertGreaterThan(capture.details("state_received")["state_age_lower_ms"] as? Double ?? -1, 1700)
        timing.decision(event: "ready", localMonotonicNs: 2001 * ms)
        XCTAssertNil(capture.events("cue_decision").last?["source_state_id"])
    }

    func testSpeechUsesSubmissionIDAndCancelledCallbackCannotClaimLatency() {
        let (timing, capture) = make()
        timing.speech(stage: "submit", id: 10, localMonotonicNs: 300 * ms)
        timing.speech(stage: "start", id: 10, localMonotonicNs: 450 * ms)
        XCTAssertEqual(capture.details("speech")["submit_to_start_callback_ms"] as? Double, 150)
        timing.speech(stage: "cancel", id: 10, localMonotonicNs: 500 * ms)
        timing.speech(stage: "start", id: 10, localMonotonicNs: 600 * ms)
        XCTAssertTrue(capture.details("speech")["submit_to_start_callback_ms"] is NSNull)
        XCTAssertNil(capture.events("speech").last?["source_state_id"])
        XCTAssertEqual(
            capture.details("speech")["causal_source"] as? String, "unavailable_no_bound_decision_identifier")
    }

    func testMissingVideoAndDisplayMeasurementsRemainExplicitlyUnavailable() {
        let (_, capture) = make()
        let details = capture.details("measurement_capabilities")
        XCTAssertTrue(details["robot_video_latency_ms"] is NSNull)
        XCTAssertTrue(details["display_presentation_latency_ms"] is NSNull)
        XCTAssertEqual(details["robot_video_unavailable_reason"] as? String, "no_robot_video_source_or_renderer")
        XCTAssertEqual(details["speech_onset_basis"] as? String, "synthesizer_didStart_callback_not_acoustic_onset")
    }

    func testDurableAcknowledgementEndsRetriesAndRetryKeepsOriginalTimestamp() {
        let (timing, capture) = make(ack: true)
        let original = capture.events("measurement_capabilities")[0]
        timing.tick(at: 1200 * ms)
        let retried = capture.events("measurement_capabilities")
        XCTAssertEqual(retried.count, 2)
        XCTAssertEqual(retried[0]["event_id"] as? String, retried[1]["event_id"] as? String)
        XCTAssertEqual(retried[0]["client_monotonic_ns"] as? UInt64, retried[1]["client_monotonic_ns"] as? UInt64)
        timing.receive(
            type: "telemetry_ack", payload: ["event_id": original["event_id"]!, "status": "persisted"],
            localMonotonicNs: 1201 * ms)
        timing.tick(at: 2400 * ms)
        XCTAssertEqual(capture.events("measurement_capabilities").count, 2)
        XCTAssertEqual(timing.unacknowledgedCount, 0)
    }

    func testUnacknowledgedEventsAreBoundedAndOverflowIsReported() {
        let (timing, capture) = make(ack: true)
        for n in 0..<140 { timing.event(kind: "voice", details: ["n": n], localMonotonicNs: 200 * ms) }
        XCTAssertEqual(timing.unacknowledgedCount, ExperimentTiming.maxPendingEvents)
        XCTAssertGreaterThan(timing.lostEventCount, 0)
        let first = capture.events("measurement_capabilities")[0]
        timing.receive(
            type: "telemetry_ack", payload: ["event_id": first["event_id"]!, "status": "persisted"],
            localMonotonicNs: 300 * ms)
        XCTAssertEqual(capture.events("telemetry_gap").count, 1)
        XCTAssertTrue(capture.details("telemetry_gap")["delivery_unknown_not_proven_lost"] as? Bool == true)
    }

    func testNoRetriesWithoutAdvertisedDurableAcknowledgements() {
        let (timing, capture) = make()
        timing.tick(at: 1200 * ms)
        XCTAssertEqual(capture.events("measurement_capabilities").count, 1)
        XCTAssertEqual(timing.unacknowledgedCount, 0)
    }

    func testReconnectReportsUnacknowledgedGapWithoutOldTrialAttribution() {
        let (timing, capture) = make(ack: true)
        timing.reset()
        timing.receive(
            type: "welcome",
            payload: [
                "telemetry_version": 1, "server_clock_id": "server-b", "connection_id": "connection-b",
                "telemetry_acknowledgements": true,
            ], localMonotonicNs: 300 * ms)
        XCTAssertEqual(capture.events("telemetry_gap").count, 1)
        XCTAssertNil(capture.events("telemetry_gap").last?["trial_id"])
        XCTAssertNil(timing.clockBounds)
    }
    func testOldOrInvalidStateCannotRetagNewTrialEvents() {
        let (timing, capture) = make()
        func receipt(_ id: Int, _ trial: String, _ clock: String = "server-a") {
            timing.receive(
                type: "state",
                payload: [
                    "timing": [
                        "state_id": id, "captured_monotonic_ns": UInt64(id) * ms,
                        "sent_monotonic_ns": UInt64(id) * ms, "server_clock_id": clock,
                    ],
                    "study": ["trial_id": trial],
                ], localMonotonicNs: 1000 * ms)
        }
        receipt(10, "new-trial")
        receipt(9, "old-trial")
        timing.event(kind: "voice", details: [:], localMonotonicNs: 1001 * ms)
        XCTAssertEqual(capture.events("voice").last?["trial_id"] as? String, "new-trial")
        XCTAssertEqual(capture.events("state_received").last?["trial_id"] as? String, "old-trial")
        receipt(10, "conflicting-duplicate-trial")
        timing.event(kind: "voice", details: [:], localMonotonicNs: 1002 * ms)
        XCTAssertEqual(capture.events("voice").last?["trial_id"] as? String, "new-trial")
        receipt(11, "wrong-clock-trial", "other-server")
        timing.event(kind: "voice", details: [:], localMonotonicNs: 1002 * ms)
        XCTAssertEqual(capture.events("voice").last?["trial_id"] as? String, "new-trial")
    }

    func testRetryExhaustionReportsUnknownDeliveryAndStopsResendingOriginal() {
        let (timing, capture) = make(ack: true)
        timing.tick(at: 1200 * ms)
        timing.tick(at: 2400 * ms)
        timing.tick(at: 3600 * ms)
        XCTAssertEqual(capture.events("measurement_capabilities").count, 3)
        XCTAssertEqual(capture.events("telemetry_gap").count, 1)
        XCTAssertEqual(timing.lostEventCount, 1)
        timing.tick(at: 4800 * ms)
        XCTAssertEqual(capture.events("measurement_capabilities").count, 3)
    }

}
