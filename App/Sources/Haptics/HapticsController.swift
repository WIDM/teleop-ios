import CoreHaptics
import TeleopCore

protocol HapticsPlaying: AnyObject {
    func run(_ command: HapticCommand)
}

final class HapticsController: HapticsPlaying {
    private var engine: CHHapticEngine?
    private var loopPlayer: CHHapticAdvancedPatternPlayer?

    init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        engine = try? CHHapticEngine()
        engine?.resetHandler = { [weak self] in try? self?.engine?.start() }
        engine?.stoppedHandler = { _ in }
        try? engine?.start()
    }

    func run(_ command: HapticCommand) {
        switch command {
        case .play(let cue): play(cue.pattern)
        case .cancel: cancel()
        }
    }

    private func play(_ pattern: HapticPattern) {
        guard let engine, let core = try? makePattern(pattern) else { return }
        try? engine.start()
        do {
            if pattern.repeats {
                let player = try engine.makeAdvancedPlayer(with: core)
                player.loopEnabled = true
                loopPlayer = player
                try player.start(atTime: CHHapticTimeImmediate)
            } else {
                let player = try engine.makePlayer(with: core)
                try player.start(atTime: CHHapticTimeImmediate)
            }
        } catch {
            return
        }
    }

    private func cancel() {
        try? loopPlayer?.stop(atTime: CHHapticTimeImmediate)
        loopPlayer = nil
    }

    private func makePattern(_ pattern: HapticPattern) throws -> CHHapticPattern {
        let strong = [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
        ]
        var events = pattern.pulses.map {
            CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: strong,
                relativeTime: Double($0.startMs) / 1000,
                duration: Double($0.durationMs) / 1000
            )
        }
        if let loop = pattern.loopLengthMs, let last = pattern.pulses.last {
            // A silent tail makes the loop cycle include the off time.
            let tailStart = last.startMs + last.durationMs
            events.append(
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 0)],
                    relativeTime: Double(tailStart) / 1000,
                    duration: Double(loop - tailStart) / 1000
                )
            )
        }
        return try CHHapticPattern(events: events, parameters: [])
    }
}

final class NoHaptics: HapticsPlaying {
    func run(_ command: HapticCommand) {}
}
