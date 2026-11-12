public struct HapticPulse: Equatable, Sendable {
    public let startMs: Int
    /// 0 for a transient: one tap with no length of its own.
    public let durationMs: Int
    public var intensity = 1.0
    public var sharpness = 0.5

    public var isTransient: Bool { durationMs == 0 }
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

/// The seven event patterns the operator feels (interaction specification §5.1, plus ON TARGET), told apart by rhythm:
/// how many, and whether each is a tick or a long buzz. Weight only reinforces it.
public enum Haptic: String, CaseIterable, Sendable {
    /// One crisp tick: your hold is live.
    case go
    /// A tick, then a soft swell: the jaws are on the target the guide shows. The only rhythm that mixes a tick and a
    /// long pulse. It opens with the tick, so its first moment never feels like a limit, and its long part is shorter,
    /// lighter and duller than END's.
    case onTarget
    /// Three quick ticks: your press did nothing.
    case no
    /// Two slow heavy thumps: the jaws closed on something.
    case grip
    /// One long buzz: as far as it goes.
    case end
    /// Two long buzzes: the app or the server ended your hold while you still hold it.
    case letGo
    /// A 1.5 s rattle: the robot is in emergency stop.
    case alarm

    /// A pulse this long or longer counts as long in the rhythm.
    public static let longPulseMs = 200

    public var pattern: HapticPattern {
        switch self {
        case .go:
            return HapticPattern(pulses: [HapticPulse(startMs: 0, durationMs: 0, intensity: 0.8, sharpness: 0.9)], loopLengthMs: nil)
        case .onTarget:
            return HapticPattern(
                pulses: [
                    HapticPulse(startMs: 0, durationMs: 0, intensity: 0.8, sharpness: 0.7),
                    HapticPulse(startMs: 110, durationMs: 240, intensity: 0.55, sharpness: 0.2),
                ],
                loopLengthMs: nil
            )
        case .no:
            return HapticPattern(
                pulses: [0, 90, 180].map { HapticPulse(startMs: $0, durationMs: 0, intensity: 1, sharpness: 1) },
                loopLengthMs: nil
            )
        case .grip:
            return HapticPattern(
                pulses: [0, 220].map { HapticPulse(startMs: $0, durationMs: 70, intensity: 1, sharpness: 0.15) },
                loopLengthMs: nil
            )
        case .end:
            return HapticPattern(pulses: [HapticPulse(startMs: 0, durationMs: 380, intensity: 0.9, sharpness: 0.5)], loopLengthMs: nil)
        case .letGo:
            return HapticPattern(
                pulses: [0, 420].map { HapticPulse(startMs: $0, durationMs: 300, intensity: 0.9, sharpness: 0.5) },
                loopLengthMs: nil
            )
        case .alarm:
            return HapticPattern(
                pulses: (0..<15).map { HapticPulse(startMs: $0 * 100, durationMs: 50, intensity: 1, sharpness: 0.8) },
                loopLengthMs: nil
            )
        }
    }

    /// Higher wins the one haptic channel: ALARM > LETGO > NO > GRIP > END > ON TARGET > GO. ON TARGET plays once per
    /// approach, so it sits above GO, which is never dropped: GO waits for it instead.
    public var priority: Int {
        switch self {
        case .alarm: return 7
        case .letGo: return 6
        case .no: return 5
        case .grip: return 4
        case .end: return 3
        case .onTarget: return 2
        case .go: return 1
        }
    }

    /// How long the pattern plays.
    public var durationMs: Int {
        pattern.pulses.map { $0.startMs + max($0.durationMs, Self.transientMs) }.max() ?? 0
    }

    /// The rhythm: one entry per pulse, true for a long one.
    public var rhythm: [Bool] { pattern.pulses.map { $0.durationMs >= Self.longPulseMs } }

    /// About how long one transient is felt.
    static let transientMs = 20
}
