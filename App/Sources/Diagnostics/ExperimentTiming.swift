import CoreFoundation
import Foundation

/// Diagnostic observations only. Trial duration belongs to the server journal.
final class ExperimentTiming {
    struct ClockBounds {
        let lowerOffsetNs: Int64
        let upperOffsetNs: Int64
        let receivedAtNs: UInt64
        let roundTripNs: UInt64
    }

    static let probeIntervalNs: UInt64 = 5_000_000_000
    static let syncLifetimeNs: UInt64 = 15_000_000_000
    static let maxRoundTripNs: UInt64 = 2_000_000_000
    static let assumedRelativeClockDriftPPM = 1000.0
    static let maxSpeechRecords = 64
    static let maxPendingEvents = 128
    static let retryIntervalNs: UInt64 = 1_000_000_000
    static let maxEventAttempts = 3

    private struct PendingEvent {
        let payload: [String: Any]
        var sentAtNs: UInt64
        var attempts: Int
    }

    let clientClockID: String
    var send: ((String, [String: Any]) -> Void)?
    private(set) var enabled = false
    private(set) var clockBounds: ClockBounds?
    private(set) var serverClockID: String?
    private(set) var connectionID: String?
    private let now: () -> UInt64
    private let makeID: () -> String
    private var probe: (id: String, sentAtNs: UInt64)?
    private var lastProbeAtNs: UInt64?
    private var trialID: String?
    private var latestState: (id: UInt64, capturedNs: UInt64)?
    private var submittedSpeech: [Int: UInt64] = [:]
    private var startedSpeech: Set<Int> = []
    private var durableAcknowledgements = false
    private var pendingEvents: [String: PendingEvent] = [:]
    private(set) var lostEventCount = 0
    private var unreportedLossCount = 0
    private var lostEventSamples: [String] = []
    var unacknowledgedCount: Int { pendingEvents.count }

    init(
        clientClockID: String = "phone:" + UUID().uuidString + ":monotonic_ns",
        now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        makeID: @escaping () -> String = { UUID().uuidString }
    ) {
        self.clientClockID = clientClockID
        self.now = now
        self.makeID = makeID
    }

    func receive(type: String, payload: [String: Any], localMonotonicNs: UInt64) {
        switch type {
        case "welcome":
            reset()
            guard Self.unsigned(payload["telemetry_version"]) == 1,
                let clock = Self.identifier(payload["server_clock_id"]),
                let connection = Self.identifier(payload["connection_id"])
            else { return }
            enabled = true
            durableAcknowledgements = payload["telemetry_acknowledgements"] as? Bool == true
            serverClockID = clock
            connectionID = connection
            record(
                kind: "measurement_capabilities",
                details: [
                    "robot_video_latency_ms": NSNull(),
                    "robot_video_unavailable_reason": "no_robot_video_source_or_renderer",
                    "display_presentation_latency_ms": NSNull(),
                    "display_unavailable_reason": "model_update_is_not_display_presentation",
                    "speech_onset_basis": "synthesizer_didStart_callback_not_acoustic_onset",
                    "delivery": durableAcknowledgements
                        ? "awaiting_durable_acknowledgement" : "submitted_without_durable_acknowledgement",
                ], at: localMonotonicNs)
            reportGaps(at: localMonotonicNs)
            requestProbe(at: localMonotonicNs)
        case "telemetry_ack":
            if durableAcknowledgements, payload["status"] as? String == "persisted",
                let id = payload["event_id"] as? String
            {
                pendingEvents[id] = nil
                reportGaps(at: localMonotonicNs)
            }
        case "clock_reply":
            receiveProbe(payload, at: localMonotonicNs)
        case "state":
            receiveState(payload, at: localMonotonicNs)
        default:
            break
        }
    }

    func tick(at time: UInt64? = nil) {
        guard enabled else { return }
        let time = time ?? now()
        retryEvents(at: time)
        reportGaps(at: time)
        if let last = lastProbeAtNs, time >= last, time - last < Self.probeIntervalNs { return }
        requestProbe(at: time)
    }

    /// Reconnect, suspension and transport loss invalidate the clock mapping and pending speech observations.
    func reset() {
        for id in pendingEvents.keys { noteLoss(id) }
        pendingEvents.removeAll()
        durableAcknowledgements = false
        enabled = false
        serverClockID = nil
        connectionID = nil
        clockBounds = nil
        probe = nil
        lastProbeAtNs = nil
        trialID = nil
        latestState = nil
        submittedSpeech.removeAll()
        startedSpeech.removeAll()
    }

    func decision(event: String, localMonotonicNs: UInt64) {
        record(
            kind: "cue_decision",
            details: ["event": event, "causal_source": "unavailable_no_bound_source_identifier"],
            at: localMonotonicNs)
    }

    func speech(stage: String, id: Int, localMonotonicNs: UInt64) {
        guard enabled else { return }
        var details: [String: Any] = [
            "utterance_id": id,
            "stage": stage,
            "causal_source": "unavailable_no_bound_decision_identifier",
        ]
        switch stage {
        case "submit":
            if submittedSpeech[id] != nil {
                details["measurement_error"] = "duplicate_utterance_submission"
            } else if submittedSpeech.count >= Self.maxSpeechRecords {
                details["measurement_error"] = "speech_measurement_capacity"
            } else {
                submittedSpeech[id] = localMonotonicNs
            }
        case "start":
            if let submitted = submittedSpeech[id], localMonotonicNs >= submitted,
                !startedSpeech.contains(id)
            {
                details["submit_to_start_callback_ms"] = Double(localMonotonicNs - submitted) / 1_000_000
                startedSpeech.insert(id)
            } else {
                details["submit_to_start_callback_ms"] = NSNull()
                details["measurement_error"] = "missing_duplicate_or_invalid_submission"
            }
        case "end", "cancel":
            submittedSpeech[id] = nil
            startedSpeech.remove(id)
        default:
            details["measurement_error"] = "unknown_speech_stage"
        }
        record(kind: "speech", details: details, at: localMonotonicNs)
    }

    func event(kind: String, details: [String: Any], localMonotonicNs: UInt64? = nil) {
        record(kind: kind, details: details, at: localMonotonicNs ?? now())
    }

    private func requestProbe(at time: UInt64) {
        guard enabled, time <= UInt64(Int64.max) else { return }
        let id = makeID()
        probe = (id, time)
        lastProbeAtNs = time
        send?("clock_probe", ["probe_id": id, "client_send_ns": time])
    }

    private func receiveProbe(_ payload: [String: Any], at time: UInt64) {
        guard enabled else { return }
        guard let expected = probe,
            payload["probe_id"] as? String == expected.id,
            payload["server_clock_id"] as? String == serverClockID,
            Self.unsigned(payload["client_send_ns"]) == expected.sentAtNs,
            let received = Self.unsigned(payload["server_receive_ns"]),
            let sent = Self.unsigned(payload["server_send_ns"]),
            time <= UInt64(Int64.max), time >= expected.sentAtNs, sent >= received,
            time - expected.sentAtNs <= Self.maxRoundTripNs,
            sent - received <= time - expected.sentAtNs
        else {
            record(kind: "clock_probe_rejected", details: ["reason": "unmatched_or_invalid_probe"], at: time)
            return
        }
        let lower = Int64(sent) - Int64(time)
        let upper = Int64(received) - Int64(expected.sentAtNs)
        clockBounds = ClockBounds(
            lowerOffsetNs: lower, upperOffsetNs: upper, receivedAtNs: time,
            roundTripNs: time - expected.sentAtNs)
        probe = nil
        record(
            kind: "clock_bound",
            details: [
                "server_minus_client_lower_ns": lower,
                "server_minus_client_upper_ns": upper,
                "round_trip_ms": Double(time - expected.sentAtNs) / 1_000_000,
                "server_processing_ms": Double(sent - received) / 1_000_000,
                "assumed_relative_clock_drift_ppm": Self.assumedRelativeClockDriftPPM,
                "one_way_exact_ms": NSNull(),
            ], at: time)
    }

    private func receiveState(_ payload: [String: Any], at time: UInt64) {
        guard enabled else { return }
        let study = payload["study"] as? [String: Any]
        let sourceTrialID = Self.identifier(study?["trial_id"])
        guard let timing = payload["timing"] as? [String: Any],
            let stateID = Self.unsigned(timing["state_id"]),
            let captured = Self.unsigned(timing["captured_monotonic_ns"]),
            let sent = Self.unsigned(timing["sent_monotonic_ns"]),
            timing["server_clock_id"] as? String == serverClockID,
            sent >= captured
        else {
            record(kind: "state_received", details: ["measurement_error": "missing_or_invalid_source_timing"], at: time)
            return
        }
        if latestState.map({ stateID > $0.id && captured >= $0.capturedNs }) ?? true {
            latestState = (stateID, captured)
            trialID = sourceTrialID
        }
        var details: [String: Any] = [
            "state_id": stateID,
            "server_clock_id": serverClockID ?? "",
            "server_state_assembled_ns": captured,
            "server_send_submission_ns": sent,
            "server_assembly_to_send_ms": Double(sent - captured) / 1_000_000,
            "source_basis": "server_state_snapshot_not_camera_capture",
            "state_age_lower_ms": NSNull(),
            "state_age_upper_ms": NSNull(),
        ]
        if let bounds = clockBounds, time >= bounds.receivedAtNs,
            time - bounds.receivedAtNs <= Self.syncLifetimeNs
        {
            let drift =
                (Double(time - bounds.receivedAtNs) + Double(bounds.roundTripNs))
                * Self.assumedRelativeClockDriftPPM / 1_000_000
            let roundoff = max(Double(time).ulp, Double(captured).ulp) * 4
            let lower = Double(time) - Double(captured) + Double(bounds.lowerOffsetNs) - drift - roundoff
            let upper = Double(time) - Double(captured) + Double(bounds.upperOffsetNs) + drift + roundoff
            if upper >= 0 {
                details["state_age_lower_ms"] = max(0, lower) / 1_000_000
                details["state_age_upper_ms"] = upper / 1_000_000
                details["assumed_relative_clock_drift_ppm"] = Self.assumedRelativeClockDriftPPM
            } else {
                details["measurement_error"] = "source_time_inconsistent_with_clock_bound"
            }
        } else {
            details["measurement_error"] = "clock_bound_missing_or_expired"
        }
        record(
            kind: "state_received", details: details, at: time, sourceStateID: stateID, sourceTrialID: sourceTrialID,
            useCurrentTrial: false)
    }

    private func record(
        kind: String, details: [String: Any], at time: UInt64, sourceStateID: UInt64? = nil,
        sourceTrialID: String? = nil, useCurrentTrial: Bool = true
    ) {
        guard enabled, time <= UInt64(Int64.max), Self.identifier(kind) != nil,
            JSONSerialization.isValidJSONObject(details)
        else { return }
        let eventID = makeID()
        var payload: [String: Any] = [
            "event_id": eventID, "client_clock_id": clientClockID,
            "client_monotonic_ns": time, "kind": kind, "details": details,
        ]
        if let sourceStateID { payload["source_state_id"] = sourceStateID }
        if let selectedTrial = useCurrentTrial ? trialID : sourceTrialID { payload["trial_id"] = selectedTrial }
        if durableAcknowledgements {
            guard pendingEvents.count < Self.maxPendingEvents else {
                noteLoss(eventID)
                return
            }
            pendingEvents[eventID] = PendingEvent(payload: payload, sentAtNs: time, attempts: 1)
        }
        send?("telemetry", payload)
    }

    private func noteLoss(_ id: String) {
        lostEventCount += 1
        unreportedLossCount += 1
        if lostEventSamples.count < 8 { lostEventSamples.append(id) }
    }

    private func retryEvents(at time: UInt64) {
        guard durableAcknowledgements else { return }
        for id in Array(pendingEvents.keys) {
            guard var event = pendingEvents[id], time >= event.sentAtNs,
                time - event.sentAtNs >= Self.retryIntervalNs
            else { continue }
            if event.attempts >= Self.maxEventAttempts {
                pendingEvents[id] = nil
                noteLoss(id)
            } else {
                event.attempts += 1
                event.sentAtNs = time
                pendingEvents[id] = event
                send?("telemetry", event.payload)
            }
        }
    }

    private func reportGaps(at time: UInt64) {
        guard unreportedLossCount > 0, pendingEvents.count < Self.maxPendingEvents else { return }
        let count = unreportedLossCount
        let samples = lostEventSamples
        unreportedLossCount = 0
        lostEventSamples = []
        record(
            kind: "telemetry_gap",
            details: [
                "unacknowledged_or_dropped_count": count,
                "sample_event_ids": samples,
                "reason": "bounded_retry_buffer_or_connection_reset",
                "delivery_unknown_not_proven_lost": true,
            ], at: time)
    }

    private static func identifier(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.count <= 256 else { return nil }
        return value
    }

    private static func unsigned(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let string = number.stringValue
        guard let value = UInt64(string), value <= UInt64(Int64.max) else { return nil }
        return value
    }
}
