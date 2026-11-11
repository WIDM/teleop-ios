// xcode: set sdk=iOS

import AVFoundation
import CoreHaptics
import TeleopCore

protocol HapticsPlaying: AnyObject {
    /// Plays the pattern now, stopping the one that plays.
    func play(_ haptic: Haptic)
    func stop()
}

/// Plays the six event patterns with Core Haptics. An audio interruption (a call, Siri) stops the engine, and
/// Apple asks apps to restart it before the next pattern, so it is restarted when the interruption ends, from its
/// own handlers, and before every pattern.
final class HapticsController: HapticsPlaying {
    private var engine: CHHapticEngine?
    private var player: CHHapticPatternPlayer?
    private var interruptions: NSObjectProtocol?

    init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        engine = try? CHHapticEngine()
        engine?.playsHapticsOnly = true
        engine?.resetHandler = { [weak self] in try? self?.engine?.start() }
        engine?.stoppedHandler = { _ in }
        try? engine?.start()
        interruptions = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            if type == .ended { try? self?.engine?.start() }
        }
    }

    deinit {
        if let interruptions { NotificationCenter.default.removeObserver(interruptions) }
    }

    func play(_ haptic: Haptic) {
        guard let engine, let pattern = try? Self.pattern(haptic.pattern) else { return }
        try? engine.start()
        stop()
        guard let player = try? engine.makePlayer(with: pattern) else { return }
        self.player = player
        try? player.start(atTime: CHHapticTimeImmediate)
    }

    func stop() {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
    }

    private static func pattern(_ pattern: HapticPattern) throws -> CHHapticPattern {
        let events = pattern.pulses.map { pulse in
            let parameters = [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(pulse.intensity)),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(pulse.sharpness)),
            ]
            return pulse.isTransient
                ? CHHapticEvent(eventType: .hapticTransient, parameters: parameters, relativeTime: Double(pulse.startMs) / 1000)
                : CHHapticEvent(
                    eventType: .hapticContinuous, parameters: parameters,
                    relativeTime: Double(pulse.startMs) / 1000, duration: Double(pulse.durationMs) / 1000
                )
        }
        return try CHHapticPattern(events: events, parameters: [])
    }
}

final class NoHaptics: HapticsPlaying {
    func play(_ haptic: Haptic) {}
    func stop() {}
}
