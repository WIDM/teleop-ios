public struct HapticPulse: Equatable, Sendable {
    public let startMs: Int
    public let durationMs: Int
}

/// Timings from haptics-v1: short buzz 60 ms with 120 ms gaps; long buzz 400 ms on / 200 ms off, repeating.
public struct HapticPattern: Equatable, Sendable {
    public static let shortOnMs = 60
    public static let shortGapMs = 120
    public static let longOnMs = 400
    public static let longOffMs = 200

    public let pulses: [HapticPulse]
    /// Non-nil means the pattern repeats until cancelled; value is one full cycle length.
    public let loopLengthMs: Int?

    public var repeats: Bool { loopLengthMs != nil }

    /// 1...3 short buzzes; nil for any other count.
    public static func shortBuzz(count: Int) -> HapticPattern? {
        guard (1...3).contains(count) else { return nil }
        let pulses = (0..<count).map {
            HapticPulse(startMs: $0 * (shortOnMs + shortGapMs), durationMs: shortOnMs)
        }
        return HapticPattern(pulses: pulses, loopLengthMs: nil)
    }

    public static let longBuzz = HapticPattern(
        pulses: [HapticPulse(startMs: 0, durationMs: longOnMs)],
        loopLengthMs: longOnMs + longOffMs
    )
}

/// The cues the app plays. They share four distinct patterns: `stopReleased` reuses the single short buzz (H15).
public enum HapticCue: CaseIterable, Sendable {
    case gripperClosed
    case gripperOpened
    case commandBlocked
    case stopReleased
    case emergencyLoop
    /// The phone is held right again (1 short) or no longer is (2 short). Same patterns as the gripper cues.
    case postureOk
    case postureOff

    public var pattern: HapticPattern {
        switch self {
        case .gripperClosed: return HapticPattern.shortBuzz(count: 1)!
        case .gripperOpened: return HapticPattern.shortBuzz(count: 2)!
        case .commandBlocked: return HapticPattern.shortBuzz(count: 3)!
        case .stopReleased: return HapticPattern.shortBuzz(count: 1)!
        case .emergencyLoop: return HapticPattern.longBuzz
        case .postureOk: return HapticPattern.shortBuzz(count: 1)!
        case .postureOff: return HapticPattern.shortBuzz(count: 2)!
        }
    }
}

public enum HapticCommand: Equatable, Sendable {
    case play(HapticCue)
    case cancel
}
